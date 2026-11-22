#if os(iOS)
  import Foundation
  import HealthKit
  import MemoirCore

  /// The `HKHealthStore` behind the Health reader. Read-only: it asks to share nothing. Apple recommends one long-lived store per app, so every reader
  /// shares `shared`.
  nonisolated struct HealthKitSampleSource: HealthSampleSource {
    static let shared = HealthKitSampleSource()

    static var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
      self.store = store
    }

    func requestReading(_ sources: Set<HealthSource>) async throws(HealthReadError) {
      let types = Set(sources.map(Self.objectType))
      try await run { try await store.requestAuthorization(toShare: [], read: types) }
    }

    func sum(of total: HealthTotal, from start: Date, to end: Date) async throws(HealthReadError) -> Double? {
      let type = HKQuantityType(Self.identifier(of: total))
      let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
      let samples = HKSamplePredicate.quantitySample(type: type, predicate: predicate)
      let statistics = try await run { try await HKStatisticsQueryDescriptor(predicate: samples, options: .cumulativeSum).result(for: store) }
      return statistics?.sumQuantity()?.doubleValue(for: Self.unit(of: total))
    }

    func changes(of kind: HealthSampleKind, after anchor: Data?, since: Date) async throws(HealthReadError) -> HealthRawChanges {
      let resumed = anchor.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
      let predicate = resumed == nil ? HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate) : nil
      let query = HKAnchoredObjectQueryDescriptor(predicates: [.sample(type: Self.sampleType(of: kind), predicate: predicate)], anchor: resumed)
      let result = try await run { try await query.result(for: store) }
      let archived: Data
      do {
        archived = try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true)
      } catch {
        throw .failed(error.localizedDescription)
      }
      let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
      let added = result.addedSamples.compactMap { sample -> HealthRawSample? in
        if kind == .sleep {
          guard let category = sample as? HKCategorySample, asleep.contains(category.value) else { return nil }
        }
        let quantity = (sample as? HKQuantitySample).flatMap { sample in Self.unit(of: kind).map { sample.quantity.doubleValue(for: $0) } }
        let zone = (sample.metadata?[HKMetadataKeyTimeZone] as? String).flatMap(TimeZone.init(identifier:))
        return HealthRawSample(id: sample.uuid, start: sample.startDate, end: sample.endDate, recordedZone: zone, quantity: quantity)
      }
      return HealthRawChanges(added: added, deleted: result.deletedObjects.map(\.uuid), anchor: archived)
    }

    private func run<T>(_ body: () async throws -> T) async throws(HealthReadError) -> T {
      do {
        return try await body()
      } catch let error as HKError {
        switch error.code {
        case .errorDatabaseInaccessible: throw .protectedDataUnavailable
        case .errorHealthDataUnavailable, .errorHealthDataRestricted: throw .unavailable
        default: throw .failed(error.localizedDescription)
        }
      } catch {
        throw .failed(error.localizedDescription)
      }
    }

    private static func identifier(of total: HealthTotal) -> HKQuantityTypeIdentifier {
      switch total {
      case .stepCount: .stepCount
      case .activeEnergy: .activeEnergyBurned
      case .dietaryWater: .dietaryWater
      }
    }

    private static func unit(of total: HealthTotal) -> HKUnit {
      switch total {
      case .stepCount: .count()
      case .activeEnergy: .kilocalorie()
      case .dietaryWater: .literUnit(with: .milli)
      }
    }

    private static func unit(of kind: HealthSampleKind) -> HKUnit? {
      switch kind {
      case .bodyMass: .gramUnit(with: .kilo)
      case .restingHeartRate: .count().unitDivided(by: .minute())
      case .waistCircumference: .meterUnit(with: .centi)
      case .sleep, .workout: nil
      }
    }

    private static func sampleType(of kind: HealthSampleKind) -> HKSampleType {
      switch kind {
      case .bodyMass: HKQuantityType(.bodyMass)
      case .restingHeartRate: HKQuantityType(.restingHeartRate)
      case .waistCircumference: HKQuantityType(.waistCircumference)
      case .sleep: HKCategoryType(.sleepAnalysis)
      case .workout: HKWorkoutType.workoutType()
      }
    }

    private static func objectType(_ source: HealthSource) -> HKObjectType {
      switch source {
      case .total(let total): HKQuantityType(identifier(of: total))
      case .samples(let kind): sampleType(of: kind)
      }
    }
  }
#endif
