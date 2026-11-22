import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// What happened recently and every choice open now, doing nothing among them (`recovery-screen.tsx`).
struct ComingBackView: View {
  @State private var model: ComingBackModel
  @State private var generation = 0
  @Environment(\.horizontalSizeClass) private var sizeClass

  init(context: MemoirScreenContext) {
    _model = State(initialValue: ComingBackModel(context: context))
  }

  var body: some View {
    content
      .navigationTitle(Text("Coming back", tableName: "Hero"))
      .task(id: generation) { await model.run() }
      .alert(failureTitle, isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }), presenting: model.failure) { _ in
        Button {
          model.failure = nil
        } label: {
          Text("OK", tableName: "Hero")
        }
      } message: { failure in
        failure.error.text
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.comingBack.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).shadowScreen(.pushed)
    case .failed(let error):
      ShadowContentUnavailable(Text("This couldn’t be read", tableName: "Hero"), systemImage: "exclamationmark.triangle", message: error.text) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "Hero")
        }
      }
      .fillingSurface()
      .shadowScreen(.pushed)
    case .loaded(let value):
      loaded(value)
    }
  }

  private func loaded(_ value: ComingBack) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        Text("What happened recently, and every choice open to you now. Doing nothing is one of them, and it costs nothing.", tableName: "Hero")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
        ShadowAdaptiveColumns {
          summary(value)
          if model.isDismissed {
            ShadowCard {
              VStack(alignment: .leading, spacing: Spacing.space2) {
                HeroCardTitle(Text("Not now", tableName: "Hero"))
                Text("These choices are set aside for today. They come back tomorrow if they still apply.", tableName: "Hero")
                  .shadowFont(.subheadline)
                  .foregroundStyle(ShadowColor.textSecondary)
              }
            }
          } else if !value.choices.isEmpty {
            choices(value)
          }
          ComingBackIntensityCard(model: model, value: value)
          if !value.recentlyMissed.isEmpty { missed(value) }
          if let comeback = value.comeback, comeback.armed || comeback.claimed { comebackProgress(comeback) }
          ShadowCard {
            VStack(alignment: .leading, spacing: Spacing.space2) {
              HeroCardTitle(Text("How shields work", tableName: "Hero"))
              Text(verbatim: HeroCopy.shieldNote(value.shields)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
            }
          }
        }
      }
      .padding(sizeClass == .compact ? Spacing.space4 : Spacing.space6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .shadowScreen(.pushed)
  }

  private func summary(_ value: ComingBack) -> some View {
    let copy = ComingBackCopy(reason: value.reason, claimed: value.comebackClaimed)
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text(verbatim: copy.headline).shadowFont(.title3).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
        Text(verbatim: copy.body).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        if let returner = value.returner { returnerFacts(returner) }
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: Spacing.space6) { facts(value) }
          VStack(alignment: .leading, spacing: Spacing.space3) { facts(value) }
        }
      }
    }
  }

  @ViewBuilder
  private func facts(_ value: ComingBack) -> some View {
    HeroTally(label: Text("HP", tableName: "Hero"), note: Text(verbatim: HeroCopy.hpNote(value.hp))) { HeroHPTally(hp: value.hp) }
    HeroTally(label: Text("Shields held", tableName: "Hero")) {
      Text(verbatim: HeroCopy.shields(value.shields)).shadowFont(.headline).monospacedDigit()
    }
    if let crown = value.crown {
      HeroTally(label: Text("Crown kept", tableName: "Hero")) {
        Text("\(crown.keptPercent)%", tableName: "Hero").shadowFont(.headline).monospacedDigit()
      }
    }
  }

  private func returnerFacts(_ returner: ReturnerStanding) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(
        verbatim: [
          String(localized: "\(returner.daysAbsent) days away", table: "Hero"),
          String(localized: "last active \(HeroDates.text(returner.lastActiveDate, year: false))", table: "Hero"),
        ]
        .joined(separator: " · "))
      if returner.shieldPending {
        Text("Your returner shield goes to the next quest you create.", tableName: "Hero")
      } else if let name = returner.shieldTargetName {
        Text("Your returner shield went to \(name).", tableName: "Hero")
      }
    }
    .shadowFont(.footnote)
    .foregroundStyle(ShadowColor.textSecondary)
  }

  private func choices(_ value: ComingBack) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HeroCardTitle(Text("Open choices", tableName: "Hero"))
        Text("Each of these is optional and reversible.", tableName: "Hero").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        ForEach(value.choices, id: \.self) { choice in
          let copy = ComingBackChoiceCopy(choice, recovery: value.recovery)
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(verbatim: copy.title).shadowFont(.subheadline).fontWeight(.semibold).foregroundStyle(ShadowColor.textPrimary)
            Text(verbatim: copy.body).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
            Text("Effect: \(copy.effect)", tableName: "Hero").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
            NavigationLink(value: MemoirRoute.destination(copy.destination)) {
              Text(verbatim: copy.action)
            }
            .buttonStyle(.shadowBordered)
          }
          .padding(.top, Spacing.space1)
        }
        Button {
          model.dismiss()
        } label: {
          Text("Not now", tableName: "Hero")
        }
        .buttonStyle(.shadowPlain)
      }
    }
  }

  private func missed(_ value: ComingBack) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HeroCardTitle(Text("Recently missed", tableName: "Hero"))
        ForEach(value.recentlyMissed) { quest in
          HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: Spacing.space05) {
              Text(verbatim: quest.name ?? String(localized: "A quest", table: "Hero")).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
              Text(verbatim: ComingBackCopy.missMeta(quest)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
            }
            Spacer(minLength: Spacing.space2)
            ShadowBadge(quest.allShielded ? Text("Shielded", tableName: "Hero") : Text("Missed", tableName: "Hero"), intent: quest.allShielded ? .info : .neutral)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func comebackProgress(_ comeback: ComebackStanding) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        HeroCardTitle(Text("Comeback progress", tableName: "Hero"))
        ProgressView(value: Double(min(comeback.fires, comeback.allowance)), total: Double(max(comeback.allowance, 1)))
          .progressViewStyle(.shadowLinear)
          .accessibilityLabel(Text("Comeback progress", tableName: "Hero"))
        Text("\(comeback.fires) of \(comeback.allowance) comeback bonuses claimed today.", tableName: "Hero")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private var failureTitle: Text {
    guard let mode = model.failure?.mode else { return Text(verbatim: "") }
    return Text("Couldn’t change intensity to ‘\(HeroCopy.intensity(mode))’", tableName: "Hero")
  }
}

struct ComingBackIntensityCard: View {
  static let order: [IntensityMode] = [.lowIntensity, .standard, .highIntensity]

  let model: ComingBackModel
  let value: ComingBack

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HeroCardTitle(Text("Intensity", tableName: "Hero"))
        Text(
          "How much the app should ask of you. This changes load and strictness across every quest at once, and it never changes experience already earned.",
          tableName: "Hero"
        )
        .shadowFont(.subheadline)
        .foregroundStyle(ShadowColor.textSecondary)
        VStack(alignment: .leading, spacing: Spacing.space2) {
          ForEach(Self.order, id: \.self) { mode in option(mode) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Intensity", tableName: "Hero"))
        if let staged = model.stagedIntensity {
          Text("\(HeroCopy.intensity(staged)) from your next rollover — \(HeroCopy.intensity(value.intensityMode)) stays active today.", tableName: "Hero")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
  }

  private func option(_ mode: IntensityMode) -> some View {
    let inForce = value.intensityMode == mode
    return Button {
      Task { await model.setIntensity(mode) }
    } label: {
      HStack(alignment: .top, spacing: Spacing.space3) {
        Image(systemName: inForce ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(inForce ? ShadowColor.accentText : ShadowColor.textTertiary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Spacing.space05) {
          HStack(spacing: Spacing.space2) {
            Text(verbatim: HeroCopy.intensity(mode)).shadowFont(.subheadline).fontWeight(.semibold).foregroundStyle(ShadowColor.textPrimary)
            if model.stagedIntensity == mode { ShadowBadge(Text("From tomorrow", tableName: "Hero"), intent: .info) }
            if model.pendingIntensity == mode { Text("Saving…", tableName: "Hero").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary) }
          }
          Text(verbatim: HeroCopy.intensityDescription(mode)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.pendingIntensity != nil)
    .accessibilityAddTraits(inForce ? .isSelected : [])
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack { ComingBackView(context: context) }.shadowTheme()
  }
}
