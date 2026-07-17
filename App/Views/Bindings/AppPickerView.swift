import SummondCore
import SwiftUI
import UniformTypeIdentifiers

struct AppPickerView: View {
  @Binding var draft: ShortcutEditorDraft
  let applications: [AppDisplayInfo]
  let isLoading: Bool
  var loadApplications: () async -> Void
  var resolveApplication: (URL) -> AppIdentity?

  @State private var searchText = ""
  @State private var selection: AppDisplayInfo.ID?
  @State private var pickerError: String?
  @State private var choosesOtherApplication = false
  @FocusState private var isSearchFocused: Bool

  private var filteredApplications: [AppDisplayInfo] {
    AppFuzzyMatch.rank(applications, searchText)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Application")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Choose Other Application…") {
          choosesOtherApplication = true
        }
        .controlSize(.small)
      }

      searchField

      Group {
        if isLoading {
          loadingView
        } else if filteredApplications.isEmpty {
          ContentUnavailableView.search(text: searchText)
        } else {
          applicationList
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if let pickerError {
        Label(pickerError, systemImage: "exclamationmark.circle")
          .font(.callout)
          .foregroundStyle(.red)
      }
    }
    .task {
      await loadApplications()
      selectCurrentApplicationIfVisible()
      isSearchFocused = true
    }
    .onChange(of: draft.bundleID) { _, bundleID in
      selection = bundleID.isEmpty ? nil : bundleID
    }
    .onChange(of: filteredApplications.map(\.id)) { _, _ in
      keepSelectionVisible()
    }
    .fileImporter(
      isPresented: $choosesOtherApplication,
      allowedContentTypes: [.applicationBundle],
      allowsMultipleSelection: false,
      onCompletion: chooseOtherApplication
    )
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Search installed applications", text: $searchText)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
        .onSubmit(selectHighlightedApplication)
        .onKeyPress(.downArrow) {
          moveSelection(by: 1)
          return .handled
        }
        .onKeyPress(.upArrow) {
          moveSelection(by: -1)
          return .handled
        }
        .accessibilityIdentifier("appPicker.search")

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }

  private var applicationList: some View {
    List(filteredApplications, selection: $selection) { app in
      AppChoiceRow(app: app, isChosen: app.bundleID == draft.bundleID)
        .tag(app.id)
        .contentShape(Rectangle())
    }
    .listStyle(.bordered(alternatesRowBackgrounds: true))
    .onChange(of: selection) { _, selectedID in
      guard
        let selectedID,
        let app = filteredApplications.first(where: { $0.id == selectedID })
      else { return }
      choose(app)
    }
    .onKeyPress(.return) {
      selectHighlightedApplication()
      return .handled
    }
  }

  private var loadingView: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Loading installed applications…")
        .foregroundStyle(.secondary)
    }
  }

  private func choose(_ app: AppDisplayInfo) {
    pickerError = nil
    selection = app.id
    draft.bundleID = app.bundleID
  }

  private func selectHighlightedApplication() {
    let app =
      selection.flatMap { selectedID in
        filteredApplications.first { $0.id == selectedID }
      } ?? filteredApplications.first
    guard let app else { return }
    choose(app)
  }

  private func moveSelection(by offset: Int) {
    guard !filteredApplications.isEmpty else { return }
    let currentIndex = selection.flatMap { selectedID in
      filteredApplications.firstIndex { $0.id == selectedID }
    }
    let proposedIndex = (currentIndex ?? (offset > 0 ? -1 : 0)) + offset
    let index = min(max(proposedIndex, 0), filteredApplications.count - 1)
    choose(filteredApplications[index])
  }

  private func keepSelectionVisible() {
    if let selection, filteredApplications.contains(where: { $0.id == selection }) {
      return
    }
    selection =
      filteredApplications.contains(where: { $0.bundleID == draft.bundleID })
      ? draft.bundleID
      : nil
  }

  private func selectCurrentApplicationIfVisible() {
    if filteredApplications.contains(where: { $0.bundleID == draft.bundleID }) {
      selection = draft.bundleID
    } else {
      selection = nil
    }
  }

  private func chooseOtherApplication(_ result: Result<[URL], any Error>) {
    guard case .success(let urls) = result, let url = urls.first else { return }
    guard let identity = resolveApplication(url) else {
      pickerError = "Choose a valid application."
      return
    }

    pickerError = nil
    draft.bundleID = identity.bundleIdentifier
    selection = identity.bundleIdentifier
  }
}

private struct AppChoiceRow: View {
  let app: AppDisplayInfo
  let isChosen: Bool

  var body: some View {
    HStack(spacing: 10) {
      AppRowIcon(url: app.url)
      Text(app.displayName)
        .lineLimit(1)
      Spacer()
      if isChosen {
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(app.displayName)
    .accessibilityValue(isChosen ? "Selected" : "")
    .accessibilityIdentifier("appRow.\(app.bundleID)")
  }
}
