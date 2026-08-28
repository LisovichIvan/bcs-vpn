import Dispatch
import Darwin
import Foundation

let configuration = FallbackProxyConfiguration.parse(arguments: CommandLine.arguments)
let fallbackProxyServer = FallbackProxyServer(configuration: configuration)

do {
    try fallbackProxyServer.start()
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
