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

import Foundation
import SystemPackage

extension SwiftSDKGenerator {
  func copyTargetSwiftFromDocker(
    targetDistribution: LinuxDistribution,
    baseDockerImage: String,
    sdkDirPath: FilePath
  ) async throws {
    logger.info("Launching a container to extract the Swift SDK for the target triple...")
    try await withDockerContainer(fromImage: baseDockerImage) { containerID in
      try await inTemporaryDirectory { generator, _ in
        let sdkUsrPath = sdkDirPath.appending("usr")
        try await generator.createDirectoryIfNeeded(at: sdkUsrPath)
        try await generator.copyFromDockerContainer(
          id: containerID,
          from: "/usr/include",
          to: sdkUsrPath.appending("include")
        )

        if case .rhel = targetDistribution {
          try await generator.runOnDockerContainer(
            id: containerID,
            command: #"""
              sh -c '
                  chmod +w /usr/lib64
                  cd /usr/lib64
                  for n in *; do
                      destination=$(readlink $n)
                      echo $destination | grep "\.\." && \
                          rm -f $n && \
                          ln -s $(basename $destination) $n
                  done
                  rm -rf pm-utils
              '
              """#
          )
        }

        if case let containerLib64 = FilePath("/usr/lib64"),
          try await generator.doesPathExist(containerLib64, inContainer: containerID)
        {
          let sdkUsrLib64Path = sdkUsrPath.appending("lib64")
          // we already checked that the path exists above, so we don't pass `failIfNotExists: false` here.
          try await generator.copyFromDockerContainer(
            id: containerID,
            from: containerLib64,
            to: sdkUsrLib64Path
          )
          try await createSymlink(at: sdkDirPath.appending("lib64"), pointingTo: "./usr/lib64")
        }

        let sdkUsrLibPath = sdkUsrPath.appending("lib")
        try await generator.createDirectoryIfNeeded(at: sdkUsrLibPath)
        var subpaths: [(subpath: String, failIfNotExists: Bool)] = [
          ("clang", true), ("gcc", true), ("swift", true), ("swift_static", true),
        ]

        // Ubuntu's multiarch directory scheme puts some libraries in
        // architecture-specific directories:
        //   https://wiki.ubuntu.com/MultiarchSpec
        // But not in all containers, so don't fail if it does not exist.
        if case .ubuntu = targetDistribution {
          subpaths += [("\(targetTriple.archName)-linux-gnu", false)]

          // Custom subpath for armv7
          if targetTriple.archName == "armv7" {
            subpaths += [("arm-linux-gnueabihf", false)]
          }
        }

        for (subpath, failIfNotExists) in subpaths {
          try await generator.copyFromDockerContainer(
            id: containerID,
            from: FilePath("/usr/lib").appending(subpath),
            to: sdkUsrLibPath.appending(subpath),
            failIfNotExists: failIfNotExists
          )
        }
        try await generator.createSymlink(at: sdkDirPath.appending("lib"), pointingTo: "usr/lib")

        // Look for 32-bit libraries to remove from RHEL-based distros
        // These are not needed, and the amazonlinux2 x86_64 symlinks are messed up
        if case .rhel = targetDistribution {
          for gccVersion in 7...13 {
            let removePath = "gcc/x86_64-redhat-linux/\(gccVersion)/32"
            if await doesFileExist(at: sdkUsrLibPath.appending(removePath)) {
              logger.warning(
                "Removing 32-bit libraries from RHEL imported sysroot",
                metadata: ["removePath": .stringConvertible(removePath)]
              )
              try await removeRecursively(at: sdkUsrLibPath.appending(removePath))
            }
          }
        }

        // Copy the ELF interpreter
        try await generator.copyFromDockerContainer(
          id: containerID,
          from: FilePath(targetTriple.interpreterPath),
          to: sdkDirPath.appending(targetTriple.interpreterPath),
          failIfNotExists: true
        )

        // Python artifacts are redundant.
        try await generator.removeRecursively(at: sdkUsrLibPath.appending("python3.10"))

        try await generator.removeRecursively(at: sdkUsrLibPath.appending("ssl"))
      }
    }
  }

  func copyTargetSwift(from distributionPath: FilePath, sdkDirPath: FilePath) async throws {
    logger.info("Copying Swift core libraries for the target triple into Swift SDK bundle...")

    for (pathWithinPackage, pathWithinSwiftSDK, isOptional) in [
      ("lib/swift", sdkDirPath.appending("usr/lib"), false),
      ("lib/swift_static", sdkDirPath.appending("usr/lib"), false),
      ("lib/clang", sdkDirPath.appending("usr/lib"), true),
      ("include", sdkDirPath.appending("usr"), false),
    ] {
      let fromPath = distributionPath.appending(pathWithinPackage)

      if isOptional && !doesFileExist(at: fromPath) {
        logger.debug(
          "Optional package path ignored since it does not exist",
          metadata: ["packagePath": .string(fromPath.string)]
        )
        continue
      }

      try await rsync(from: fromPath, to: pathWithinSwiftSDK)
    }
  }
}

extension Triple {
  var interpreterPath: String {
    switch self.archName {
    case "x86_64": return "/lib64/ld-linux-x86-64.so.2"
    case "aarch64": return "/lib/ld-linux-aarch64.so.1"
    case "armv7": return "/lib/ld-linux-armhf.so.3"
    default: fatalError("unsupported architecture \(self.archName)")
    }
  }
}
