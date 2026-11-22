import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// The vault's devices and which one runs its jobs: the Devices and Worker tab of the Mac Settings window, where worker mode is turned on and off, and a
/// read-only page on iPhone and iPad, which never run as the worker.
struct DevicesAndWorkerView: View {
  let store: VaultStore?
  let jobs: JobRuntimes
  #if os(macOS)
    let worker: WorkerModel
  #endif
  @State private var model = DevicesModel()

  private var engine: JobEngine? {
    guard let store, let runtime = jobs.existing(for: store), runtime.runsJobs else { return nil }
    return runtime.engine
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        workerSection
        DevicesSection(devices: model.devices, worker: model.worker)
      }
      .padding(Spacing.space4)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .background(ShadowColor.surfaceApp)
    .task(id: store.map(ObjectIdentifier.init)) {
      guard let store else { return }
      await model.followDevices(in: store)
    }
    .task(id: engine.map(ObjectIdentifier.init)) { await model.followWorker(engine) }
    #if os(macOS)
      .task { worker.refreshLoginItem() }
      .alert(
        Text("Something went wrong", tableName: "Worker"), isPresented: Binding(get: { worker.failure != nil }, set: { if !$0 { worker.failure = nil } }),
        presenting: worker.failure
      ) { _ in
        Button {
          worker.failure = nil
        } label: {
          Text("OK", tableName: "Worker")
        }
      } message: { failure in
        failure.text
      }
    #endif
  }

  @ViewBuilder
  private var workerSection: some View {
    #if os(macOS)
      WorkerSection(worker: worker, shown: model.worker)
    #else
      ShadowGroupedSection {
        WorkerStateText(worker: model.worker).padding(Spacing.space3)
      } header: {
        Text("Worker", tableName: "Worker").shadowFont(.headline)
      } footer: {
        Text(
          "A Mac turns on worker mode in its Novel Forge settings. The chapters this device asks for wait for that Mac, or for Run on This Device.",
          tableName: "Worker")
      }
    #endif
  }
}

/// Which device runs the vault's jobs, as one line.
private struct WorkerStateText: View {
  let worker: VaultWorker?

  var body: some View {
    text.foregroundStyle(ShadowColor.textSecondary)
  }

  private var text: Text {
    switch worker {
    case nil: Text("Which Mac runs jobs shows once the library is open here.", tableName: "Worker")
    case .some(.none): Text("No Mac runs jobs.", tableName: "Worker")
    case .unreadable: Text("This device can't read which Mac runs jobs.", tableName: "Worker")
    case .retired: Text("The Mac that ran jobs has left this library.", tableName: "Worker")
    case .named(let device) where device.isHere: Text("This Mac runs jobs.", tableName: "Worker")
    case .named(let device):
      device.name.map { Text("Jobs run on \($0).", tableName: "Worker") } ?? Text("Jobs run on another Mac.", tableName: "Worker")
    }
  }
}

private struct DevicesSection: View {
  let devices: [DevicesModel.Device]
  let worker: VaultWorker?

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        ForEach(devices) { device in
          DeviceRow(device: device, runsJobs: worker?.device?.replica == device.replica)
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("Devices", tableName: "Worker").shadowFont(.headline)
    } footer: {
      Text("Each device names itself when it joins this library's sync. A library that doesn't sync lists only this device.", tableName: "Worker")
    }
  }
}

private struct DeviceRow: View {
  let device: DevicesModel.Device
  let runsJobs: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        name
        if let platform = device.platform, platform != device.name {
          Text(verbatim: platform).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        }
      }
      Spacer(minLength: Spacing.space2)
      if device.isHere { ShadowBadge(Text("This Device", tableName: "Worker"), intent: .neutral) }
      if runsJobs { ShadowBadge(Text("Runs Jobs", tableName: "Worker"), intent: .info, systemImage: "gearshape.2") }
    }
  }

  private var name: Text {
    device.name.map { Text(verbatim: $0) } ?? Text("Unnamed device", tableName: "Worker")
  }
}

#if os(macOS)
  private struct WorkerSection: View {
    let worker: WorkerModel
    let shown: VaultWorker?

    var body: some View {
      ShadowGroupedSection {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          if let notice = worker.notice { NoticeCallout(notice: notice) { worker.dismissNotice() } }
          Toggle(isOn: Binding(get: { worker.isOn }, set: { on in Task { on ? await worker.turnOn() : await worker.turnOff() } })) {
            Text("Run Jobs on This Mac", tableName: "Worker")
          }
          .toggleStyle(.switch)
          .disabled(worker.change != nil || !(worker.isOn || worker.canDesignate))
          if !worker.canDesignate { unattached.foregroundStyle(ShadowColor.textSecondary) }
          WorkerStateText(worker: shown ?? worker.worker)
          if worker.isOn { LoginItemRow(worker: worker) }
        }
        .padding(Spacing.space3)
      } header: {
        Text("Worker", tableName: "Worker").shadowFont(.headline)
      } footer: {
        Text(
          "While this is on, Novel Forge opens in the menu bar when you log in, without a library window, keeps running when you close its windows and runs the chapter jobs your other devices ask for. Jobs run only while this Mac is awake.",
          tableName: "Worker")
      }
    }

    private var unattached: Text {
      guard worker.isOn else { return Text("Open the library in this copy of Novel Forge to turn this on.", tableName: "Worker") }
      return Text(
        "The library isn't open in this copy of Novel Forge. Turning this off stops this Mac at once, and your other devices learn of it once the library opens here again.",
        tableName: "Worker")
    }
  }

  private struct NoticeCallout: View {
    let notice: WorkerModel.Notice
    let dismiss: () -> Void

    var body: some View {
      ShadowCallout(text, intent: .warning, dismiss: ShadowCalloutDismiss(Text("Dismiss", tableName: "Worker"), action: dismiss)) { EmptyView() }
    }

    private var text: Text {
      switch notice {
      case .takenOver(let name?): Text("\(name) now runs jobs, so worker mode turned off on this Mac.", tableName: "Worker")
      case .takenOver(nil): Text("Another Mac now runs jobs, so worker mode turned off on this Mac.", tableName: "Worker")
      case .stoppedElsewhere: Text("No Mac runs jobs any more, so worker mode turned off on this Mac.", tableName: "Worker")
      case .libraryChanged: Text("Worker mode was on for another library, so it turned off. Turn it on again to run this library's jobs.", tableName: "Worker")
      }
    }
  }

  private struct LoginItemRow: View {
    let worker: WorkerModel

    var body: some View {
      switch worker.loginItem {
      case .status(.enabled):
        Label {
          Text("Opens when you log in.", tableName: "Worker")
        } icon: {
          Image(systemName: "checkmark.circle")
        }
        .foregroundStyle(ShadowColor.textSecondary)
      case .status(.requiresApproval):
        ShadowCallout(
          Text("Allow Novel Forge in Login Items", tableName: "Worker"),
          message: Text("Novel Forge opens when you log in only once you allow it in System Settings.", tableName: "Worker"), intent: .warning
        ) {
          Button {
            worker.openLoginItemsSettings()
          } label: {
            Text("Open Login Items Settings", tableName: "Worker")
          }
        }
      case .status(.notRegistered):
        HStack {
          Text("Doesn't open when you log in.", tableName: "Worker").foregroundStyle(ShadowColor.textSecondary)
          Spacer(minLength: Spacing.space3)
          Button {
            worker.registerLoginItem()
          } label: {
            Text("Open at Login", tableName: "Worker")
          }
        }
      case .status(.notFound), .refused(LoginItemError(reason: .invalidSignature)):
        ShadowCallout(
          Text("This build can't open at login", tableName: "Worker"),
          message: Text("Opening at login needs a build signed with a development team. Worker mode runs while Novel Forge is open.", tableName: "Worker"),
          intent: .warning
        ) { EmptyView() }
      case .refused(let error):
        ShadowCallout(
          Text("Novel Forge couldn't be added to Login Items", tableName: "Worker"), message: Text(verbatim: error.code), intent: .warning
        ) {
          Button {
            worker.registerLoginItem()
          } label: {
            Text("Try Again", tableName: "Worker")
          }
        }
      }
    }
  }
#endif
