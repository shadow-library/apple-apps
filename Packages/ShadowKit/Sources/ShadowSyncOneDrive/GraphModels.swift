import Foundation

struct GraphFacet: Decodable, Equatable {}

struct GraphParentReference: Decodable, Equatable {
  let id: String?
}

struct GraphItem: Decodable, Equatable {
  let id: String
  let name: String?
  let size: Int?
  let eTag: String?
  let cTag: String?
  let file: GraphFacet?
  let folder: GraphFacet?
  let deleted: GraphFacet?
  let parentReference: GraphParentReference?
  let lastModifiedDateTime: Date?
}

struct GraphDeltaPage: Decodable {
  let value: [GraphItem]
  let nextLink: URL?
  let deltaLink: URL?

  enum CodingKeys: String, CodingKey {
    case value
    case nextLink = "@odata.nextLink"
    case deltaLink = "@odata.deltaLink"
  }
}

struct GraphUploadSession: Decodable {
  let uploadUrl: URL?
  let nextExpectedRanges: [String]?
}

struct GraphErrorBody: Decodable {
  struct Detail: Decodable {
    let code: String?
    let innerError: Box?

    enum CodingKeys: String, CodingKey {
      case code
      case innerError = "innererror"
    }

    var codes: [String] {
      [code].compactMap(\.self) + (innerError?.detail.codes ?? [])
    }
  }

  final class Box: Decodable {
    let detail: Detail

    init(from decoder: any Decoder) throws {
      detail = try Detail(from: decoder)
    }
  }

  let error: Detail?

  static func codes(in data: Data) -> [String] {
    (try? JSONDecoder().decode(GraphErrorBody.self, from: data))?.error?.codes ?? []
  }
}

struct GraphBatchRequest: Encodable {
  struct Request: Encodable {
    let id: String
    let method: String
    let url: String
  }

  let requests: [Request]
}

struct GraphBatchResponse: Decodable {
  struct Response: Decodable {
    let id: String
    let status: Int
    let headers: [String: String]
    let codes: [String]

    enum CodingKeys: String, CodingKey {
      case id
      case status
      case headers
      case body
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      status = try container.decode(Int.self, forKey: .status)
      let headers = (try? container.decodeIfPresent([String: String].self, forKey: .headers)) ?? [:]
      self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
      codes = (try? container.decodeIfPresent(GraphErrorBody.self, forKey: .body))?.error?.codes ?? []
    }
  }

  let responses: [Response]
}
