import Foundation
import IPAToolCore

// 简单的 CLI 入口
let arguments = CommandLine.arguments

func printUsage() {
    print("ipatool - A native macOS tool for interacting with Apple's App Store")
    print("Usage: ipatool <command> [options]")
    print("Commands:")
    print("  auth          Authenticate with the App Store")
    print("  search        Search for apps on the App Store")
    print("  download      Download an app package")
    print("  purchase      Purchase an app")
    print("  test-unicorn  Test the Unicorn engine (SAP)")
    print("  test-machimage Test Mach-O image parsing")
    print("  test-machine  Test SAP machine")
}

if arguments.count < 2 || arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(0)
}

let command = arguments[1]

switch command {
case "auth":
    let client = AppStoreClient()
    guard arguments.count >= 4 else {
        print("Usage: ipatool auth <email> <password> [code]")
        exit(1)
    }
    let email = arguments[2]
    let password = arguments[3]
    let code = arguments.count > 4 ? arguments[4] : nil

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let identity = try currentMachineIdentity()
            let bag = try await client.fetchBag()
            let assets = SAPAssets(directory: SAPAssets.defaultCacheDirectory)
            let signer = try await SAPSigner(assets: assets)
            try await signer.setup(
                hardwareID: identity.hardwareID,
                version: bag.version,
                certificateURL: bag.certificateURL,
                setupURL: bag.setupURL
            )
            let info = try await client.login(
                email: email,
                password: password,
                code: code,
                signer: signer,
                authEndpoint: bag.authEndpoint,
                guid: identity.guid
            )
            print("Logged in as: \(info.name) (DSID: \(info.directoryServicesID))")
            signer.close()
        } catch {
            print("Auth failed: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()

case "search":
    let client = AppStoreClient()
    guard arguments.count >= 3 else {
        print("Usage: ipatool search <term>")
        exit(1)
    }
    let term = arguments[2]

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let apps = try await client.search(term: term)
            for app in apps {
                print("\(app.trackId)\t\(app.bundleId)\t\(app.trackName)\t\(app.version)")
            }
        } catch {
            print("Search failed: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()

case "purchase":
    let client = AppStoreClient()
    guard arguments.count >= 3 else {
        print("Usage: ipatool purchase <appID>")
        exit(1)
    }
    guard let appID = Int(arguments[2]) else {
        print("Invalid app ID")
        exit(1)
    }

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            try await client.purchase(appID: appID)
            print("Purchased app \(appID)")
        } catch {
            print("Purchase failed: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()

case "test-unicorn":
    let defaultPath = NSHomeDirectory() + "/Library/Caches/ipatool/unicorn/2.1.4/7207c8e3d7a63118fb0bca73e01816797fd51b1d8a39a4cbc7abfd562ee59c85/libunicorn.2.dylib"
    let path = arguments.count > 2 ? arguments[2] : defaultPath
    let ok = IPAToolCore.testUnicorn(dylibPath: path)
    exit(ok ? 0 : 1)

case "test-machimage":
    guard arguments.count > 2 else {
        print("Usage: ipatool test-machimage <path-to-macho>")
        exit(1)
    }
    let ok = IPAToolCore.testMachImage(path: arguments[2])
    exit(ok ? 0 : 1)

case "test-machine":
    let assetsDir = arguments.count > 2 ? arguments[2] :
        NSHomeDirectory() + "/Library/Caches/ipatool/sap/apple-assets-v2"
    let unicornPath = arguments.count > 3 ? arguments[3] :
        NSHomeDirectory() + "/Library/Caches/ipatool/unicorn/2.1.4/7207c8e3d7a63118fb0bca73e01816797fd51b1d8a39a4cbc7abfd562ee59c85/libunicorn.2.dylib"
    let ok = IPAToolCore.testMachine(assetsDir: assetsDir, unicornPath: unicornPath)
    exit(ok ? 0 : 1)

default:
    print("Unknown command: \(command)")
    printUsage()
    exit(1)
}
