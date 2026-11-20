import Foundation
import ShadowCore

public enum S3ConfigurationError: ShadowError, Equatable {
  case insecureEndpoint
  case invalidEndpoint(String)
  case invalidRegion
  case invalidBucket
  case dottedBucketNeedsPathStyle
  case invalidKeyPrefix
  case invalidCredentials(String)

  public var code: String {
    switch self {
    case .insecureEndpoint: "s3.insecure_endpoint"
    case .invalidEndpoint: "s3.invalid_endpoint"
    case .invalidRegion: "s3.invalid_region"
    case .invalidBucket: "s3.invalid_bucket"
    case .dottedBucketNeedsPathStyle: "s3.dotted_bucket_needs_path_style"
    case .invalidKeyPrefix: "s3.invalid_key_prefix"
    case .invalidCredentials: "s3.invalid_credentials"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .insecureEndpoint: "The endpoint must be https; plain http is allowed only for a loopback endpoint that opts in."
    case .invalidEndpoint(let reason): "The endpoint is invalid: \(reason)"
    case .invalidRegion: "The region must be 1 to 64 lowercase letters, digits, hyphens or underscores."
    case .invalidBucket: "The bucket name does not follow the S3 naming rules."
    case .dottedBucketNeedsPathStyle: "A bucket name with dots needs path-style addressing, since its virtual host fails TLS validation."
    case .invalidKeyPrefix: "The key prefix must be empty or slash-separated segments of letters, digits, dots, hyphens and underscores."
    case .invalidCredentials(let reason): "The credentials are invalid: \(reason)"
    }
  }
}
