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
    @State private var contentHeight: CGFloat = 0
    @State private var showsDone = false

    private var total: Int { model.tasks.count + model.completedToday.count }

    var body: some View {
        PanelScroll {
            VStack(alignment: .leading, spacing: 18) {
                TodayHeader(done: model.completedToday.count, total: total)
                section(title: L("Tasks"), systemImage: "checklist", count: model.tasks.count) {
                    AddField(
                        text: $model.newTaskTitle, placeholder: L("Add a task"),
                        submit: { withAnimation(Theme.spring) { model.addTask() } })
                    if model.tasks.isEmpty {
                        EmptyHint(
                            systemImage: total > 0 ? "party.popper.fill" : "sun.max.fill",
                            text: total > 0
                                ? L("All done for today. Nice work!")
                                : L("Nothing to do. Enjoy it, or ask me to plan your day."))
                    } else {
                        card {
                            ForEach(model.tasks) { task in
                                TaskRow(task: task, model: model)
                                if task.id != model.tasks.last?.id { RowDivider() }
                            }
                        }
                    }
                    if !model.completedToday.isEmpty {
                        Button {
                            withAnimation(Theme.spring) { showsDone.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(showsDone ? 90 : 0))
                                Text(
                                    verbatim: String(
                                        format: L("Done today (%lld)"), model.completedToday.count))
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 4)
                        if showsDone {
                            card {
                                ForEach(model.completedToday) { task in
                                    TaskRow(task: task, model: model)
                                }
                            }
                            .transition(.opacity.combined(with: .offset(y: -6)))
                        }
                    }
                }
                section(title: L("Habits"), systemImage: "flame.fill", count: model.habits.count) {
                    AddField(
                        text: $model.newHabitName, placeholder: L("Add a habit"),
                        submit: { withAnimation(Theme.spring) { model.addHabit() } })
                    if model.habits.isEmpty {
                        EmptyHint(
                            systemImage: "leaf.fill",
                            text: L("Track small daily wins, like drinking water."))
                    }
                    ForEach(model.habits) { habit in HabitCard(habit: habit, model: model) }
                }
            }
            .padding(16)
            .animation(Theme.spring, value: model.tasks)
            .animation(Theme.spring, value: model.completedToday)
            .animation(Theme.spring, value: model.habits)
            .measureHeight($contentHeight)
        }
        .preference(key: PanelHeightKey.self, value: contentHeight)
    }

    private func section<Content: View>(
        title: String, systemImage: String, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(verbatim: title).font(.system(size: 14, weight: .bold, design: .rounded))
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.card, in: Capsule())
                        .contentTransition(.numericText())
                }
            }
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The date, a friendly line and how much of today is done.
private struct TodayHeader: View {
    var done: Int
    var total: Int

    private var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(verbatim: summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            ZStack {
                Circle().stroke(Theme.card, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Theme.userBubble, style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                if total > 0 && done == total {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(verbatim: "\(done)/\(total)")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: 42, height: 42)
            .animation(Theme.spring, value: progress)
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Theme.accent.opacity(0.16), Theme.pastels[2].opacity(0.1)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var summary: String {
        let left = total - done
        if total == 0 { return greeting() }
        if left == 0 { return L("Everything's done. You're amazing!") }
        return left == 1
            ? L("One thing left to do.") : String(format: L("%lld things left to do."), left)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 30)
    }
}

/// A round checkbox that pops when ticked.
private struct CheckCircle: View {
    var isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? Color.clear : Theme.secondaryText, lineWidth: 1.5)
            if isOn {
                Circle().fill(Theme.userBubble)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.75))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 18, height: 18)
        .scaleEffect(isOn ? 1 : 0.94)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isOn)
    }
}

private struct TaskRow: View {
    var task: TaskItem
    var model: TodayModel
    @State private var ticked = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                // Tick right away, then let the list move the task.
                ticked = true
                model.toggle(task)
            } label: {
                CheckCircle(isOn: task.isDone || ticked)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .accessibilityLabel(task.isDone ? L("Mark as not done") : L("Mark as done"))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? Theme.tertiaryText : .white)
                if let due = task.dueDate ?? task.remindAt, !task.isDone {
                    Label {
                        Text(due, format: .relative(presentation: .named))
                    } icon: {
                        Image(systemName: task.remindAt != nil ? "bell.fill" : "calendar")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(due < Date() ? Theme.danger : Theme.secondaryText)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("Delete"), role: .destructive) {
                withAnimation(Theme.spring) { model.delete(task) }
            }
        }
    }
}

/// A habit with its streak and the last seven days.
private struct HabitCard: View {
    var habit: Habit
    var model: TodayModel

    private var lastWeek: [Date] {
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: Date())
        }
    }

    var body: some View {
        let isDone = habit.isDone()
        let color = Theme.pastel(for: habit.id)
        HStack(spacing: 12) {
            Button {
                model.toggle(habit)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isDone ? color : color.opacity(0.14))
                    Image(systemName: isDone ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(isDone ? .black.opacity(0.7) : color)
                }
                .frame(width: 34, height: 34)
                .scaleEffect(isDone ? 1 : 0.94)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isDone)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? L("Mark as not done") : L("Mark as done"))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: habit.name).font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    ForEach(lastWeek, id: \.self) { day in
                        Circle()
                            .fill(habit.isDone(on: day) ? color : Color.white.opacity(0.1))
                            .frame(width: 7, height: 7)
                    }
                }
            }
            Spacer()
            let streak = habit.streak()
            if streak > 0 {
                Label {
                    Text(verbatim: "\(streak)").contentTransition(.numericText())
                } icon: {
                    Image(systemName: "flame.fill")
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.orange)
                .help(String(format: L("%lld-day streak"), streak))
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button(L("Delete"), role: .destructive) {
                withAnimation(Theme.spring) { model.delete(habit) }
            }
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
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
            PanelTextField(text: $text, placeholder: placeholder, submit: submit)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
    }
}

/// A gentle message where a list is empty.
struct EmptyHint: View {
    var systemImage: String = "sparkles"
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text(verbatim: text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
