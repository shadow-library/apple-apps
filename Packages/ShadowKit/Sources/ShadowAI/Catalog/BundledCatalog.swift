import Foundation

enum CatalogBundledJSON {
  static let text = """
    {
      "format": 1,
      "models": [
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-fable-5-2",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 200000000,
            "cacheWriteLong": 16000000000,
            "cacheWriteShort": 10000000000,
            "input": 8000000000,
            "output": 40000000000
          },
          "successors": [],
          "supportsJSONSchema": true
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-fable-5-1",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 250000000,
            "cacheWriteLong": 20000000000,
            "cacheWriteShort": 12500000000,
            "input": 10000000000,
            "output": 50000000000
          },
          "successors": [
            "claude-fable-5-2"
          ],
          "supportsJSONSchema": true
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-fable-5",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 1000000000,
            "cacheWriteLong": 20000000000,
            "cacheWriteShort": 12500000000,
            "input": 10000000000,
            "output": 50000000000
          },
          "successors": [
            "claude-fable-5-2"
          ],
          "supportsJSONSchema": true
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-opus-5-5",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 200000000,
            "cacheWriteLong": 8000000000,
            "cacheWriteShort": 5000000000,
            "input": 4000000000,
            "output": 20000000000
          },
          "successors": [],
          "supportsJSONSchema": true
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-opus-5",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 500000000,
            "cacheWriteLong": 10000000000,
            "cacheWriteShort": 6250000000,
            "input": 5000000000,
            "output": 25000000000
          },
          "successors": [
            "claude-opus-5-5"
          ],
          "supportsJSONSchema": true
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-opus-4-8",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 500000000,
            "cacheWriteLong": 10000000000,
            "cacheWriteShort": 6250000000,
            "input": 5000000000,
            "output": 25000000000
          },
          "successors": [
            "claude-opus-5-5"
          ],
          "supportsJSONSchema": true
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-opus-4-7",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 500000000,
            "cacheWriteLong": 10000000000,
            "cacheWriteShort": 6250000000,
            "input": 5000000000,
            "output": 25000000000
          },
          "successors": [
            "claude-opus-5-5"
          ],
          "supportsJSONSchema": false
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "max"
          ],
          "id": "claude-opus-4-6",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 500000000,
            "cacheWriteLong": 10000000000,
            "cacheWriteShort": 6250000000,
            "input": 5000000000,
            "output": 25000000000
          },
          "successors": [
            "claude-opus-5-5"
          ],
          "supportsJSONSchema": false
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-sonnet-5-5",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 100000000,
            "cacheWriteLong": 4000000000,
            "cacheWriteShort": 2500000000,
            "input": 2000000000,
            "output": 10000000000
          },
          "successors": [],
          "supportsJSONSchema": true
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-sonnet-5",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 200000000,
            "cacheWriteLong": 4000000000,
            "cacheWriteShort": 2500000000,
            "input": 2000000000,
            "output": 10000000000
          },
          "successors": [
            "claude-sonnet-5-5"
          ],
          "supportsJSONSchema": true
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "max"
          ],
          "id": "claude-sonnet-4-6",
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 300000000,
            "cacheWriteLong": 6000000000,
            "cacheWriteShort": 3750000000,
            "input": 3000000000,
            "output": 15000000000
          },
          "successors": [
            "claude-sonnet-5-5"
          ],
          "supportsJSONSchema": false
        },
        {
          "contextTokens": 1000000,
          "efforts": [
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
          ],
          "id": "claude-haiku-5-5",
          "longPrompt": {
            "aboveTokens": 100000,
            "pricing": {
              "cacheRead": 50000000,
              "cacheWriteLong": 1000000000,
              "cacheWriteShort": 625000000,
              "input": 500000000,
              "output": 2500000000
            }
          },
          "maxOutputTokens": 128000,
          "pricing": {
            "cacheRead": 10000000,
            "cacheWriteLong": 200000000,
            "cacheWriteShort": 125000000,
            "input": 100000000,
            "output": 500000000
          },
          "successors": [],
          "supportsJSONSchema": true
        },
        {
          "contextTokens": 200000,
          "efforts": [],
          "id": "claude-haiku-4-5",
          "maxOutputTokens": 64000,
          "pricing": {
            "cacheRead": 100000000,
            "cacheWriteLong": 2000000000,
            "cacheWriteShort": 1250000000,
            "input": 1000000000,
            "output": 5000000000
          },
          "successors": [
            "claude-haiku-5-5"
          ],
          "supportsJSONSchema": true
        }
      ],
      "revision": 1,
      "routes": {
        "chat": {
          "meticulous": {
            "effort": "high",
            "maxOutputTokens": 32000,
            "model": "claude-fable-5-2"
          },
          "steady": {
            "effort": "medium",
            "maxOutputTokens": 32000,
            "model": "claude-sonnet-5-5"
          },
          "swift": {
            "effort": "low",
            "maxOutputTokens": 32000,
            "model": "claude-haiku-5-5"
          }
        },
        "helper": {
          "meticulous": {
            "effort": "high",
            "maxOutputTokens": 16000,
            "model": "claude-haiku-5-5"
          },
          "steady": {
            "effort": "medium",
            "maxOutputTokens": 16000,
            "model": "claude-haiku-5-5"
          },
          "swift": {
            "effort": "low",
            "maxOutputTokens": 16000,
            "model": "claude-haiku-5-5"
          }
        },
        "planning": {
          "meticulous": {
            "effort": "high",
            "maxOutputTokens": 32000,
            "model": "claude-fable-5-2"
          },
          "steady": {
            "effort": "medium",
            "maxOutputTokens": 32000,
            "model": "claude-sonnet-5-5"
          },
          "swift": {
            "effort": "low",
            "maxOutputTokens": 32000,
            "model": "claude-sonnet-5-5"
          }
        },
        "review": {
          "meticulous": {
            "effort": "high",
            "maxOutputTokens": 32000,
            "model": "claude-fable-5-2"
          },
          "steady": {
            "effort": "medium",
            "maxOutputTokens": 32000,
            "model": "claude-sonnet-5-5"
          },
          "swift": {
            "effort": "low",
            "maxOutputTokens": 32000,
            "model": "claude-sonnet-5-5"
          }
        },
        "writing": {
          "meticulous": {
            "effort": "high",
            "maxOutputTokens": 64000,
            "model": "claude-fable-5-2"
          },
          "steady": {
            "effort": "medium",
            "maxOutputTokens": 64000,
            "model": "claude-sonnet-5-5"
          },
          "swift": {
            "effort": "low",
            "maxOutputTokens": 64000,
            "model": "claude-sonnet-5-5"
          }
        }
      }
    }
    """
}

extension ModelCatalog {
  public static let bundled: ModelCatalog = {
    do {
      return try ModelCatalog(decoding: Data(CatalogBundledJSON.text.utf8))
    } catch {
      preconditionFailure("The bundled model catalog does not decode: \(error)")
    }
  }()
}
