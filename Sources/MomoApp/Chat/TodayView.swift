import MomoKit
import SwiftUI

/// Mirrors the store's tasks and habits for the Today tab.
@MainActor
@Observable
final class TodayModel {
    private(set) var tasks: [TaskItem] = []
    private(set) var completedToday: [TaskItem] = []
    private(set) var habits: [Habit] = []
    var newTaskTitle = ""
    var newHabitName = ""

    let store: MomoStore
    @ObservationIgnored private var observation: Task<Void, Never>?
    /// Called when the user finishes a task, for a small celebration.
    @ObservationIgnored var onTaskCompleted: (() -> Void)?

    init(store: MomoStore) {
        self.store = store
        observation = Task { [weak self] in
            let stream = await store.changes()
            for await data in stream {
                self?.apply(data)
            }
        }
    }

    private func apply(_ data: MomoData) {
        let calendar = Calendar.current
        tasks = data.tasks.filter { !$0.isDone }
            .sorted {
                ($0.dueDate ?? .distantFuture, $0.createdAt)
                    < ($1.dueDate ?? .distantFuture, $1.createdAt)
            }
        completedToday = data.tasks.filter {
            $0.isDone && $0.completedAt.map { calendar.isDateInToday($0) } == true
        }
        habits = data.habits.sorted { $0.createdAt < $1.createdAt }
    }

    func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        newTaskTitle = ""
        Task { try? await store.addTask(title: title) }
    }

    func toggle(_ task: TaskItem) {
        if !task.isDone { onTaskCompleted?() }
        Task { try? await store.setTaskDone(id: task.id, !task.isDone) }
    }

    func delete(_ task: TaskItem) {
        Task { try? await store.deleteTask(task.id) }
    }

    func addHabit() {
        let name = newHabitName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newHabitName = ""
        Task { try? await store.addHabit(name: name) }
    }

    func toggle(_ habit: Habit) {
        if !habit.isDone() { onTaskCompleted?() }
        Task { try? await store.logHabit(habit.id, done: !habit.isDone()) }
    }

    func delete(_ habit: Habit) {
        Task { try? await store.deleteHabit(habit.id) }
    }
}

/// Tasks and habits at a glance.
struct TodayView: View {
    @Bindable var model: TodayModel

    var body: some View {
        PanelScroll {
            VStack(alignment: .leading, spacing: 20) {
                section(title: L("Tasks"), count: model.tasks.count) {
                    AddField(
                        text: $model.newTaskTitle, placeholder: L("Add a task"),
                        submit: model.addTask)
                    if model.tasks.isEmpty && model.completedToday.isEmpty {
                        EmptyHint(text: L("Nothing to do. Enjoy it, or ask me to plan your day."))
                    }
                    ForEach(model.tasks) { task in TaskRow(task: task, model: model) }
                    ForEach(model.completedToday) { task in TaskRow(task: task, model: model) }
                }
                section(title: L("Habits"), count: model.habits.count) {
                    AddField(
                        text: $model.newHabitName, placeholder: L("Add a habit"),
                        submit: model.addHabit)
                    if model.habits.isEmpty {
                        EmptyHint(text: L("Track small daily wins, like drinking water."))
                    }
                    ForEach(model.habits) { habit in HabitRow(habit: habit, model: model) }
                }
            }
            .padding(16)
        }
    }

    private func section<Content: View>(
        title: String, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: title).font(.system(size: 14, weight: .bold, design: .rounded))
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.card, in: Capsule())
                }
            }
            content()
        }
    }
}

private struct TaskRow: View {
    var task: TaskItem
    var model: TodayModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                model.toggle(task)
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.isDone ? Theme.accent : Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? L("Mark as not done") : L("Mark as done"))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? Theme.tertiaryText : .white)
                if let due = task.dueDate ?? task.remindAt {
                    Label {
                        Text(due, format: .relative(presentation: .named))
                    } icon: {
                        Image(systemName: task.remindAt != nil ? "bell" : "calendar")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(
                        due < Date() && !task.isDone ? Theme.danger : Theme.secondaryText)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(L("Delete"), role: .destructive) { model.delete(task) }
        }
    }
}

private struct HabitRow: View {
    var habit: Habit
    var model: TodayModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.toggle(habit)
            } label: {
                Image(systemName: habit.isDone() ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(habit.isDone() ? Theme.accent : Theme.secondaryText)
            }
            .buttonStyle(.plain)
            Text(verbatim: habit.name).font(.system(size: 13))
            Spacer()
            let streak = habit.streak()
            if streak > 0 {
                Label {
                    Text(verbatim: "\(streak)")
                } icon: {
                    Image(systemName: "flame.fill")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.orange)
                .help(String(format: L("%lld-day streak"), streak))
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(L("Delete"), role: .destructive) { model.delete(habit) }
        }
    }
}

/// A single-line field with a plus button.
struct AddField: View {
    @Binding var text: String
    var placeholder: String
    var submit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(Theme.accent)
            PanelTextField(text: $text, placeholder: placeholder, submit: submit)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyHint: View {
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiaryText)
            .padding(.vertical, 4)
    }
}

/// A plain text field that renders as its placeholder in snapshot mode.
struct PanelTextField: View {
    @Binding var text: String
    var placeholder: String
    var submit: () -> Void = {}
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode {
            Text(verbatim: placeholder)
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(text: $text, prompt: Text(verbatim: placeholder)) {
                Text(verbatim: placeholder)
            }
            .textFieldStyle(.plain)
            .onSubmit(submit)
        }
    }
}
