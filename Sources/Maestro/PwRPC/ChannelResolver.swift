import Foundation
import SwiftProtobuf

/// Probes the candidate Maestro channels in parallel by sending GetSoftwareInfo
/// on each. The first to respond with a valid SoftwareInfo is the active channel
/// for this RFCOMM session.
public enum ChannelResolver {
    /// Probes candidate Maestro channels sequentially, returning the first that responds.
    /// Sequential probing avoids the buds rejecting concurrent in-flight requests on
    /// distinct channels.
    public static func resolve(
        on connection: RpcConnection,
        perCandidateTimeout seconds: TimeInterval = 0.5,
        logger: ((String) -> Void)? = nil
    ) async throws -> UInt32 {
        let path = RpcPath("maestro_pw.Maestro/GetSoftwareInfo")
        
        // Interleaved probing order prioritizing bud channels:
        // buds left/right A/B interleaved, then case A/B
        let interleavedOrder: [UInt32] = [19, 24, 21, 26, 18, 23]
        
        for channel in interleavedOrder {
            try Task.checkCancellation()
            logger?("trying candidate channel \(channel)…")
            let start = Date()
            do {
                try await probe(connection: connection, channel: channel, path: path, timeout: seconds)
                logger?("channel \(channel) responded in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
                
                // Either bud channel serves reads and streams equally well. We
                // used to pick between them by writing a setting back to each
                // bud, which meant a settings write on every connect. Now the
                // first responsive channel wins, and BudsViewModel's write path
                // moves to the other bud only if a real write is refused there.
                return channel
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger?("channel \(channel) failed: \(error)")
                continue
            }
        }
        throw RpcError.channelResolutionFailed
    }

    private static func probe(
        connection: RpcConnection,
        channel: UInt32,
        path: RpcPath,
        timeout: TimeInterval
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await connection.unary(
                    channel: channel,
                    path: path,
                    request: SwiftProtobuf.Google_Protobuf_Empty()
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RpcError.channelResolutionFailed
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
