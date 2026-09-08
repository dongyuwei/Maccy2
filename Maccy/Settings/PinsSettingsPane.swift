import SwiftData
import SwiftUI

struct PinPickerView: View {
  @Bindable var item: HistoryItem
  var availablePins: [String]

  var body: some View {
    if let pin = item.pin {
      // Ensure unique pins for ForEach
      let uniquePins = Array(Set(availablePins + [pin])).sorted()
      Picker("", selection: $item.pin) {
        ForEach(uniquePins, id: \.self) { pin in
          Text(pin)
            .tag(pin as String?)
        }
      }
      .controlSize(.small)
      .labelsHidden()
      .accessibilityLabel(Text("Key", tableName: "PinsSettings"))
    }
  }
}

struct PinTitleView: View {
  @Bindable var item: HistoryItem

  var body: some View {
    TextField("", text: $item.title)
      .accessibilityLabel(Text("Alias", tableName: "PinsSettings"))
  }
}

struct PinValueView: View {
  @Bindable var item: HistoryItem
  @State private var editableValue: String
  @State private var isTextContent: Bool
  @State private var isRichText: Bool
  @State private var isRevealed: Bool = false
  @FocusState private var isEditing: Bool
  @State private var showWarningPopover: Bool = false

  init(item: HistoryItem) {
    self.item = item
    self._editableValue = State(initialValue: item.previewableText)

    // Check if this item has editable text content
    let hasPlainText = item.text != nil
    let hasImage = item.image != nil
    let hasFileURLs = !item.fileURLs.isEmpty
    let hasRichText = item.rtf != nil || item.html != nil

    // Consider it text content only if it has plain text and doesn't have images or file URLs
    self._isTextContent = State(initialValue: hasPlainText && !hasImage && !hasFileURLs)
    self._isRichText = State(initialValue: hasRichText && !hasImage && !hasFileURLs)
  }

  var body: some View {
    Group {
      if isTextContent || isRichText {
        if item.isSensitive && !isRevealed {
          HStack(spacing: 4) {
            Text(verbatim: HistoryItem.maskedText(for: editableValue))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
              isRevealed = true
            } label: {
              Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help(Text("Reveal", tableName: "PinsSettings"))
          }
        } else {
          ZStack(alignment: .trailing) {
            TextField("", text: $editableValue)
              .focused($isEditing)
              .onSubmit {
                updateItemContent()
              }
              .onChange(of: editableValue) { _, _ in
                updateItemContent()
              }
              .padding(.trailing, trailingOverlayWidth)
              .accessibilityLabel(Text("Content", tableName: "PinsSettings"))

            HStack(spacing: 4) {
              Spacer(minLength: 0)
              if isRichText && isEditing {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundColor(.orange)
                  .help(Text("RichTextEditWarning", tableName: "PinsSettings"))
              }
              if item.isSensitive {
                Button {
                  isRevealed = false
                } label: {
                  Image(systemName: "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(Text("Conceal", tableName: "PinsSettings"))
              }
            }
            .padding(.trailing, 4)
          }
        }
      } else {
        // Non-editable display for non-text content
        Text("ContentIsNotText", tableName: "PinsSettings")
          .foregroundStyle(.secondary)
          .italic()
      }
    }
  }

  private var trailingOverlayWidth: CGFloat {
    var width: CGFloat = 0
    if isRichText && isEditing {
      width += 20
    }
    if item.isSensitive {
      width += 24
    }
    return width == 0 ? 0 : width + 8
  }

  private func updateItemContent() {
    // Only update if we're dealing with text or rich text content
    guard isTextContent || isRichText else { return }

    // Remove all non-plain-text content
    let stringType = NSPasteboard.PasteboardType.string.rawValue
    item.contents.removeAll { $0.type != stringType }

    // Update or add the plain text content
    if let index = item.contents.firstIndex(where: { $0.type == stringType }) {
      if let data = editableValue.data(using: .utf8) {
        item.contents[index].value = data
      }
    } else {
      if let data = editableValue.data(using: .utf8) {
        let newContent = HistoryItemContent(type: stringType, value: data)
        item.contents.append(newContent)
      }
    }
    // We don't automatically update title here since we want to preserve
    // OCR-extracted titles for images and other non-text content
  }
}

struct PinsSettingsPane: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var modelContext

  @Query(filter: #Predicate<HistoryItem> { $0.pin != nil }, sort: \.pinOrder)
  private var items: [HistoryItem]

  @State private var availablePins: [String] = []
  @State private var selection: PersistentIdentifier?

  var body: some View {
    VStack(alignment: .leading) {
      Table(items, selection: $selection) {
        TableColumn(Text("Order", tableName: "PinsSettings")) { item in
          HStack(spacing: 2) {
            Button {
              movePin(item, offset: -1)
            } label: {
              Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(item.pinOrder <= minPinOrder)
            .accessibilityLabel(Text("MoveUp", tableName: "PinsSettings"))

            Button {
              movePin(item, offset: 1)
            } label: {
              Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(item.pinOrder >= maxPinOrder)
            .accessibilityLabel(Text("MoveDown", tableName: "PinsSettings"))
          }
        }
        .width(60)

        TableColumn(Text("Key", tableName: "PinsSettings")) { item in
          PinPickerView(item: item, availablePins: availablePins)
            .onChange(of: item.pin) {
              availablePins = HistoryItem.availablePins(in: items)
            }
        }
        .width(60)

        TableColumn(Text("Alias", tableName: "PinsSettings")) { item in
          PinTitleView(item: item)
        }

        TableColumn(Text("Sensitive", tableName: "PinsSettings")) { item in
          Button {
            item.isSensitive.toggle()
            persist()
          } label: {
            Image(systemName: item.isSensitive ? "eye.slash.fill" : "eye.slash")
          }
          .buttonStyle(.borderless)
          .help(Text(item.isSensitive ? "Conceal" : "Reveal", tableName: "PinsSettings"))
        }
        .width(70)

        TableColumn(Text("Content", tableName: "PinsSettings")) { item in
          PinValueView(item: item)
        }
      }
      .onAppear {
        availablePins = HistoryItem.availablePins(in: items)
      }
      .onDeleteCommand {
        guard let selection,
              let item = appState.history.items.first(where: { $0.item.id == selection }) else {
          return
        }

        appState.history.delete(item)
      }

      Text("PinCustomizationDescription", tableName: "PinsSettings")
        .foregroundStyle(.gray)
        .controlSize(.small)
    }
    .frame(minWidth: 500, minHeight: 400)
    .padding()
  }

  private var minPinOrder: Int {
    items.map(\.pinOrder).min() ?? 0
  }

  private var maxPinOrder: Int {
    items.map(\.pinOrder).max() ?? 0
  }

  // Moves the pin within the manual order and refreshes the popup list.
  private func movePin(_ item: HistoryItem, offset: Int) {
    guard let index = items.firstIndex(where: { $0.id == item.id }) else {
      return
    }

    let targetIndex = index + offset
    guard items.indices.contains(targetIndex) else {
      return
    }

    var reordered = items
    reordered.swapAt(index, targetIndex)
    for (order, item) in reordered.enumerated() {
      item.pinOrder = order + 1
    }
    persist()

    Task {
      try? await appState.history.load()
    }
  }

  private func persist() {
    modelContext.processPendingChanges()
    try? modelContext.save()
  }
}

#Preview {
  return PinsSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
    .modelContainer(Storage.shared.container)
}
