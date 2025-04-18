//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Helpers
import Logging

import class Foundation.ByteCountFormatter
import struct SystemPackage.FilePath

struct DownloadArtifactQuery: Query {
  var cacheKey: some CacheKey { self.artifact }
  let artifact: DownloadableArtifacts.Item
  let httpClient: any HTTPClientProtocol
  let logger: Logger

  func run(engine: QueryEngine) async throws -> FilePath {
    logger.info(
      "Downloading remote artifact not available in local cache",
      metadata: ["remoteUrl": .string(self.artifact.remoteURL.absoluteString)]
    )
    let stream = self.httpClient.streamDownloadProgress(
      from: self.artifact.remoteURL,
      to: self.artifact.localPath
    )
    .removeDuplicates(by: didProgressChangeSignificantly)
    ._throttle(for: .seconds(1))

    for try await progress in stream {
      report(progress: progress, for: self.artifact)
    }
    return self.artifact.localPath
  }

  private func report(progress: DownloadProgress, for artifact: DownloadableArtifacts.Item) {
    let byteCountFormatter = ByteCountFormatter()

    if let total = progress.totalBytes {
      logger.debug(
        """
        \(artifact.remoteURL.lastPathComponent) \(
          byteCountFormatter
            .string(fromByteCount: Int64(progress.receivedBytes))
        )/\(
          byteCountFormatter
            .string(fromByteCount: Int64(total))
        )
        """
      )
    } else {
      logger.debug(
        "\(artifact.remoteURL.lastPathComponent) \(byteCountFormatter.string(fromByteCount: Int64(progress.receivedBytes)))"
      )
    }
  }
}

/// Checks whether two given progress value are different enough from each other. Used for filtering out progress
/// values in async streams with `removeDuplicates` operator.
/// - Parameters:
///   - previous: Preceding progress value in the stream.
///   - current: Currently processed progress value in the stream.
/// - Returns: `true` if `totalBytes` value is different by any amount or if `receivedBytes` is different by amount
/// larger than 1MiB. Returns `false` otherwise.
@Sendable
private func didProgressChangeSignificantly(
  previous: DownloadProgress,
  current: DownloadProgress
) -> Bool {
  guard previous.totalBytes == current.totalBytes else {
    return true
  }

  return current.receivedBytes - previous.receivedBytes > 1024 * 1024 * 1024
}
