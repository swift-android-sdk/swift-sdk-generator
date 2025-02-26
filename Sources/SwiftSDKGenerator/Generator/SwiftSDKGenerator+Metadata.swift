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

import SystemPackage

import class Foundation.JSONEncoder

private let encoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
  return encoder
}()

extension SwiftSDKGenerator {
  func generateToolsetJSON(recipe: SwiftSDKRecipe) throws -> FilePath {
    logger.info("Generating toolset JSON file...")

    let toolsetJSONPath = pathsConfiguration.swiftSDKRootPath.appending("toolset.json")

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.swiftSDKRootPath)
    else {
      fatalError(
        "`toolchainBinDirPath` is at an unexpected location that prevents computing a relative path"
      )
    }

    var toolset = Toolset(rootPath: relativeToolchainBinDir.string)
    recipe.applyPlatformOptions(toolset: &toolset, targetTriple: self.targetTriple)
    try writeFile(at: toolsetJSONPath, encoder.encode(toolset))

    return toolsetJSONPath
  }

  func generateDestinationJSON(toolsetPath: FilePath, sdkDirPath: FilePath, recipe: SwiftSDKRecipe) throws {
    logger.info("Generating destination JSON file...")

    let destinationJSONPath = pathsConfiguration.swiftSDKRootPath.appending("swift-sdk.json")

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath
    var relativeSDKDir = sdkDirPath
    var relativeToolsetPath = toolsetPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.swiftSDKRootPath),
      relativeSDKDir.removePrefix(pathsConfiguration.swiftSDKRootPath),
      relativeToolsetPath.removePrefix(pathsConfiguration.swiftSDKRootPath)
    else {
      fatalError("""
      `toolchainBinDirPath`, `sdkDirPath`, and `toolsetPath` are at unexpected locations that prevent computing \
      relative paths
      """)
    }

    var metadata = SwiftSDKMetadataV4.TripleProperties(
      sdkRootPath: relativeSDKDir.string,
      toolsetPaths: [relativeToolsetPath.string]
    )

    recipe.applyPlatformOptions(
      metadata: &metadata,
      paths: pathsConfiguration,
      targetTriple: self.targetTriple
    )

    try writeFile(
      at: destinationJSONPath,
      encoder.encode(
        SwiftSDKMetadataV4(
          targetTriples: [
            self.targetTriple.triple: metadata,
          ]
        )
      )
    )
  }

  func generateArtifactBundleManifest(hostTriples: [Triple]?) throws {
    logger.info("Generating .artifactbundle info JSON file...")

    let artifactBundleManifestPath = pathsConfiguration.artifactBundlePath.appending("info.json")

    try writeFile(
      at: artifactBundleManifestPath,
      encoder.encode(
        ArtifactsArchiveMetadata(
          schemaVersion: "1.0",
          artifacts: [
            artifactID: .init(
              type: .swiftSDK,
              version: self.bundleVersion,
              variants: [
                .init(
                  path: FilePath(artifactID).appending(self.targetTriple.triple).string,
                  supportedTriples: hostTriples.map { $0.map(\.triple) }
                ),
              ]
            ),
          ]
        )
      )
    )
  }

  struct SDKSettings: Codable {
    var DisplayName: String
    var Version: String
    var VersionMap: [String: String] = [:]
    var CanonicalName: String
  }

  /// Generates an `SDKSettings.json` file that looks like this:
  /// 
  /// ```json
  /// {
  ///   "CanonicalName" : "<arch>-swift-linux-[gnu|gnueabihf]",
  ///   "DisplayName" : "Swift SDK for <distribution> (<arch>)",
  ///   "Version" : "0.0.1",
  ///   "VersionMap" : {
  ///
  ///   }
  /// }
  /// ```
  func generateSDKSettingsFile(sdkDirPath: FilePath, distribution: LinuxDistribution) throws {
    logger.info("Generating SDKSettings.json file to silence cross-compilation warnings...")

    let sdkSettings = SDKSettings(
      DisplayName: "Swift SDK for \(distribution) (\(targetTriple.archName))",
      Version: bundleVersion,
      CanonicalName: targetTriple.triple.replacingOccurrences(of: "unknown", with: "swift")
    )

    let sdkSettingsFilePath = sdkDirPath.appending("SDKSettings.json")
    try writeFile(at: sdkSettingsFilePath, encoder.encode(sdkSettings))
  }
}
