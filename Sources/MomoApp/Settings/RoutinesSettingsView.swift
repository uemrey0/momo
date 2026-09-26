import MomoKit
import SwiftUI

/// Mirrors the store's routines for Settings.
@MainActor
@Observable
final class RoutinesModel {
    private(set) var routines: [Routine] = []
    let store: MomoStore

    init(store: MomoStore) {
        self.store = store
        Task { [weak self] in
            for await data in await store.changes() {
                // Stops listening once Settings no longer shows the routines.
                guard let self else { return }
                routines = data.routines.sorted { $0.createdAt < $1.createdAt }
            }
        }
    }

    func save(_ routine: Routine) {
        Task { try? await store.saveRoutine(routine) }
    }

    func setEnabled(_ routine: Routine, _ enabled: Bool) {
        var changed = routine
        changed.isEnabled = enabled
        save(changed)
    }

    func delete(_ routine: Routine) {
        Task { try? await store.deleteRoutine(routine.id) }
    }
}

/// Routines: prompts Momo runs by itself on a schedule.
struct RoutinesSettingsView: View {
    var model: AppModel
    @State private var routines: RoutinesModel
    @State private var editing: Routine?
    @State private var deleting: Routine?

    init(model: AppModel) {
        self.model = model
        _routines = State(initialValue: RoutinesModel(store: model.store))
    }

    var body: some View {
        Form {
            Section {
                if routines.routines.isEmpty {
                    Text(verbatim: L("No routines yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(routines.routines) { routine in
                    RoutineRow(
                        routine: routine,
                        isEnabled: Binding(
                            get: { routine.isEnabled },
                            set: { routines.setEnabled(routine, $0) }),
                        edit: { editing = routine },
                        runNow: { model.routines.runNow(routine) },
                        delete: { deleting = routine })
                }
                Button(L("Add Routine…")) {
                    editing = Routine(
                        title: "", prompt: "",
                        schedule: RoutineSchedule(
                            hour: 9, minute: 0, weekdays: RoutineSchedule.workweek))
                }
            } footer: {
                Text(
                    verbatim: L(
                        "Momo runs each routine at its time, adds the answer to the chat and lets you know with a notification. If your Mac was asleep, it catches up once when it wakes. You can also ask Momo to set one up, like “every weekday at 9, summarise my day”."
                    ))
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { routine in
            RoutineEditor(routine: routine) { saved in
                routines.save(saved)
                editing = nil
            } cancel: {
                editing = nil
            }
        }
        .confirmationDialog(
            String(format: L("Delete the routine “%@”?"), deleting?.title ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { routine in
            Button(L("Delete"), role: .destructive) { routines.delete(routine) }
        }
    }
}

private struct RoutineRow: View {
    var routine: Routine
    @Binding var isEnabled: Bool
    var edit: () -> Void
    var runNow: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: routine.title)
                Text(verbatim: routine.schedule.localizedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: routine.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(L("Edit…"), action: edit)
            Toggle(isOn: $isEnabled) { Text(verbatim: routine.title) }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("Run Now"), action: runNow)
            Button(L("Edit…"), action: edit)
            Divider()
            Button(L("Delete…"), role: .destructive, action: delete)
        }
    }
}

/// Edits a routine's title, prompt and schedule.
private struct RoutineEditor: View {
    enum Days: Hashable {
        case everyDay, weekdays, custom
    }

    @State private var routine: Routine
    @State private var time: Date
    @State private var days: Days
    @State private var customDays: Set<Int>
    var save: (Routine) -> Void
    var cancel: () -> Void

    init(routine: Routine, save: @escaping (Routine) -> Void, cancel: @escaping () -> Void) {
        _routine = State(initialValue: routine)
        let schedule = routine.schedule
        _time = State(
            initialValue: Calendar.current.date(
                bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date())
                ?? Date())
        let days: Days =
            schedule.isDaily
            ? .everyDay : schedule.weekdays == RoutineSchedule.workweek ? .weekdays : .custom
        _days = State(initialValue: days)
        _customDays = State(
            initialValue: schedule.isDaily ? RoutineSchedule.workweek : schedule.weekdays)
        self.save = save
        self.cancel = cancel
    }

    private var canSave: Bool {
        !routine.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (days != .custom || !customDays.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField(
                    L("Title"), text: $routine.title, prompt: Text(verbatim: L("Morning brief")))
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L("What should Momo do?"))
                    TextEditor(text: $routine.prompt)
                        .font(.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
                DatePicker(L("Time"), selection: $time, displayedComponents: .hourAndMinute)
                Picker(L("Days"), selection: $days) {
                    Text(verbatim: L("Every day")).tag(Days.everyDay)
                    Text(verbatim: L("Weekdays")).tag(Days.weekdays)
                    Text(verbatim: L("Custom")).tag(Days.custom)
                }
                if days == .custom {
                    WeekdayPicker(selection: $customDays)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) { save(finished()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }

    private func finished() -> Routine {
        var result = routine
        result.title = routine.title.trimmingCharacters(in: .whitespaces)
        result.prompt = routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let weekdays: Set<Int> =
            switch days {
            case .everyDay: []
            case .weekdays: RoutineSchedule.workweek
            case .custom: customDays
            }
        result.schedule = RoutineSchedule(
            hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: weekdays)
        return result
    }
}

/// Toggle buttons for the days of the week, in the user's calendar order.
private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RoutineSchedule.orderedWeekdays, id: \.self) { day in
                let isOn = selection.contains(day)
                Button {
                    if isOn { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(verbatim: Calendar.current.veryShortStandaloneWeekdaySymbols[day - 1])
                        .font(.callout.weight(.medium))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(isOn ? Color.accentColor : Color.primary.opacity(0.08))
                        )
                        .foregroundStyle(isOn ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.standaloneWeekdaySymbols[day - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

extension RoutineSchedule {
    /// Weekday numbers in the order the user's calendar starts its week.
    static var orderedWeekdays: [Int] {
        let first: Int = Calendar.current.firstWeekday
        return (0..<7).map { (offset: Int) -> Int in (first - 1 + offset) % 7 + 1 }
    }

    /// "Weekdays at 09:00", in the user's language and time format.
    var localizedSummary: String {
        let date =
            Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
            ?? Date()
        let time = date.formatted(date: .omitted, time: .shortened)
        if isDaily { return String(format: L("Every day at %@"), time) }
        if weekdays == Self.workweek { return String(format: L("Weekdays at %@"), time) }
        if weekdays == Self.weekend { return String(format: L("Weekends at %@"), time) }
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        let names = Self.orderedWeekdays.filter(weekdays.contains).map { symbols[$0 - 1] }
        return String(
            format: L("%@ at %@", comment: "Routine schedule: days, then a time"),
            names.joined(separator: ", "), time)
    }
}
