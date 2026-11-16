import Compression
import Foundation

enum CodecDeflate {
  static let outputChunkSize = 64 * 1024

  // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951) with no zlib header or checksum.
  static func deflate(_ data: Data, capacity: Int) -> Data? {
    guard capacity > 0, !data.isEmpty else { return nil }
    var output = Data(count: capacity)
    let written = output.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        guard let target = destination.bindMemory(to: UInt8.self).baseAddress, let origin = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return compression_encode_buffer(target, capacity, origin, source.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written > 0, written <= capacity else { return nil }
    output.count = written
    return output
  }

  // The decoder consumes and ignores bytes after the end of the stream, so trailing data cannot be detected here.
  static func inflate(_ data: Data, limit: Int) throws(VaultCodecError) -> Data {
    let result: Result<Data, VaultCodecError> = data.withUnsafeBytes { source in
      guard let origin = source.bindMemory(to: UInt8.self).baseAddress else { return .failure(.malformed("empty deflate stream")) }
      return inflate(origin, count: source.count, limit: limit)
    }
    return try result.get()
  }

  private static func inflate(_ origin: UnsafePointer<UInt8>, count: Int, limit: Int) -> Result<Data, VaultCodecError> {
    let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { stream.deallocate() }
    guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return .failure(.malformed("inflater unavailable")) }
    defer { compression_stream_destroy(stream) }
    stream.pointee.src_ptr = origin
    stream.pointee.src_size = count
    let flags = Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)
    var output: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: outputChunkSize)
    while true {
      let pendingInput = stream.pointee.src_size
      let (status, produced) = buffer.withUnsafeMutableBufferPointer { destination -> (compression_status, Int) in
        guard let target = destination.baseAddress else { return (COMPRESSION_STATUS_ERROR, 0) }
        stream.pointee.dst_ptr = target
        stream.pointee.dst_size = destination.count
        let status = compression_stream_process(stream, flags)
        return (status, destination.count - stream.pointee.dst_size)
      }
      guard produced <= limit - output.count else { return .failure(.payloadTooLarge) }
      if output.count + produced > output.capacity { output.reserveCapacity(min(limit, max(output.count + produced, 2 * output.capacity))) }
      output.append(contentsOf: buffer[0..<produced])
      switch status {
      case COMPRESSION_STATUS_END:
        return .success(Data(output))
      case COMPRESSION_STATUS_OK:
        guard produced > 0 || stream.pointee.src_size < pendingInput else { return .failure(.malformed("truncated deflate stream")) }
      default:
        return .failure(.malformed("invalid deflate stream"))
      }
    }
  }
}
