import Cocoa
import Core
import KanaKanjiConverterModule

/// The look of the candidate windows, after the system's input methods: a menu's material and corners, rows with no
/// rules between them, the numbers in a column of their own, and the selected row as a rounded bar in the accent color
enum CandidateWindowStyle {
    static let font = NSFont.systemFont(ofSize: 16)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let annotationFont = NSFont.systemFont(ofSize: 12)
    static let rowHeight: CGFloat = 26
    /// Above the first row and below the last, as in a menu
    static let verticalPadding: CGFloat = 5
    /// From the window's sides to the selection bar
    static let selectionInset: CGFloat = 5
    static let selectionRadius: CGFloat = 5
    /// From the window's left edge to the first thing in a row (the number, or the text when there is none)
    static let leadingInset: CGFloat = 12
    /// The numbers' column, up to where the text starts
    static let numberColumnWidth: CGFloat = 20
    static let annotationGap: CGFloat = 16
    static let trailingInset: CGFloat = 12
    static let minimumWidth: CGFloat = 96
    static let cornerRadius: CGFloat = 10
}

class NonClickableTableView: NSTableView {
    override func rightMouseDown(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
}

/// Draws the selected row as the system's menus and input methods do. The candidate window never becomes the key
/// window, so the row always takes itself as emphasized: otherwise the selection would be gray
class CandidateTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = self.bounds.insetBy(dx: CandidateWindowStyle.selectionInset, dy: 1)
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: CandidateWindowStyle.selectionRadius,
            yRadius: CandidateWindowStyle.selectionRadius
        ).fill()
    }
}

class CandidateTableCellView: NSTableCellView {
    let numberTextField: NSTextField
    let candidateTextField: NSTextField
    let candidateAnnotationTextField: NSTextField
    private lazy var candidateTextFieldLeadingConstraint: NSLayoutConstraint = {
        self.candidateTextField.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: CandidateWindowStyle.leadingInset)
    }()
    private lazy var candidateTextFieldTrailingToAnnotationConstraint: NSLayoutConstraint = {
        self.candidateTextField.trailingAnchor.constraint(
            lessThanOrEqualTo: self.candidateAnnotationTextField.leadingAnchor,
            constant: -CandidateWindowStyle.annotationGap
        )
    }()
    private lazy var candidateTextFieldTrailingToContainerConstraint: NSLayoutConstraint = {
        self.candidateTextField.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -CandidateWindowStyle.trailingInset)
    }()
    private lazy var candidateAnnotationTextFieldTrailingConstraint: NSLayoutConstraint = {
        self.candidateAnnotationTextField.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -CandidateWindowStyle.trailingInset)
    }()

    override init(frame frameRect: NSRect) {
        self.numberTextField = Self.makeLabel(font: CandidateWindowStyle.numberFont)
        self.candidateTextField = Self.makeLabel(font: CandidateWindowStyle.font)
        self.candidateTextField.lineBreakMode = .byTruncatingTail
        self.candidateAnnotationTextField = Self.makeLabel(font: CandidateWindowStyle.annotationFont)
        self.candidateAnnotationTextField.alignment = .right
        super.init(frame: frameRect)
        for field in [self.numberTextField, self.candidateTextField, self.candidateAnnotationTextField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview(field)
        }

        NSLayoutConstraint.activate([
            self.numberTextField.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: CandidateWindowStyle.leadingInset),
            self.numberTextField.firstBaselineAnchor.constraint(equalTo: self.candidateTextField.firstBaselineAnchor),
            self.candidateTextFieldLeadingConstraint,
            self.candidateTextField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.candidateAnnotationTextField.firstBaselineAnchor.constraint(equalTo: self.candidateTextField.firstBaselineAnchor)
        ])
        self.candidateTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.candidateTextField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.candidateAnnotationTextField.setContentHuggingPriority(.required, for: .horizontal)
        self.candidateAnnotationTextField.setContentCompressionResistancePriority(.required, for: .horizontal)

        self.showNumberColumn(false)
        self.showCandidateAnnotationTextField(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeLabel(font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        return field
    }

    /// The text color of a row, selected or not, for the text, the numbers and the annotations
    func applyColors(selected: Bool) {
        self.candidateTextField.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        self.numberTextField.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        self.candidateAnnotationTextField.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    /// Whether the rows have the numbers' column before the text (the text moves right to make room for it)
    func showNumberColumn(_ show: Bool) {
        self.numberTextField.isHidden = !show
        self.candidateTextFieldLeadingConstraint.constant = CandidateWindowStyle.leadingInset
            + (show ? CandidateWindowStyle.numberColumnWidth : 0)
    }

    func showCandidateAnnotationTextField(_ show: Bool) {
        self.candidateTextFieldTrailingToContainerConstraint.isActive = !show
        self.candidateTextFieldTrailingToAnnotationConstraint.isActive = show
        self.candidateAnnotationTextFieldTrailingConstraint.isActive = show
        self.candidateAnnotationTextField.isHidden = !show
    }
}

class BaseCandidateViewController: NSViewController {
    internal var candidates: [CandidatePresentation] = []
    internal var tableView: NSTableView!
    internal var currentSelectedRow: Int = -1

    override func loadView() {
        // Parent view (works like a ZStack)
        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false

        // Material view (background), the one menus use
        let materialView = NSVisualEffectView()
        materialView.blendingMode = .behindWindow
        materialView.material = .menu
        materialView.state = .active
        materialView.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view (foreground)
        let scrollView = NSScrollView()
        self.tableView = NonClickableTableView()
        self.tableView.style = .plain
        scrollView.documentView = self.tableView
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Add subviews in stacking order (back to front)
        containerView.subviews = [materialView, scrollView]

        // Constraints
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: containerView.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: CandidateWindowStyle.verticalPadding),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -CandidateWindowStyle.verticalPadding)
        ])

        self.tableView.backgroundColor = .clear
        self.tableView.gridStyleMask = []
        self.tableView.intercellSpacing = .zero

        // Table view setup
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CandidatesColumn"))
        self.tableView.headerView = nil
        self.tableView.addTableColumn(column)
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.selectionHighlightStyle = .regular
        self.tableView.rowHeight = CandidateWindowStyle.rowHeight

        self.view = containerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureWindowForRoundedCorners()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowForRoundedCorners()
    }

    internal func configureWindowForRoundedCorners() {
        guard let window = self.view.window else {
            return
        }

        window.contentView?.wantsLayer = true
        window.contentView?.layer?.masksToBounds = true

        window.styleMask = [.borderless, .resizable]
        window.isMovable = true
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        window.contentView?.layer?.cornerRadius = CandidateWindowStyle.cornerRadius
        window.backgroundColor = .clear
        window.isOpaque = false
    }

    /// Shows the candidates for the text on `lineRect` (the client's line at the text, in screen coordinates)
    func updateCandidatePresentations(_ candidates: [CandidatePresentation], selectionIndex: Int?, lineRect: CGRect) {
        self.candidates = candidates
        self.currentSelectedRow = selectionIndex ?? -1
        self.tableView.reloadData()
        self.resizeWindowToFitContent(lineRect: lineRect)
        // A selection change caused by redrawing is not a user action, so do not report it.
        self.updateSelection(to: selectionIndex ?? -1, notifySelectionChange: false)
    }

    internal func updateSelection(to row: Int, notifySelectionChange: Bool = true) {
        if row == -1 {
            return
        }
        self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        self.tableView.scrollRowToVisible(row)
        self.updateSelectionCallback(row, notifySelectionChange: notifySelectionChange)
        self.currentSelectedRow = row
        self.updateVisibleRows()
    }

    internal func updateSelectionCallback(_ row: Int, notifySelectionChange: Bool) {}

    internal func updateVisibleRows() {
        let visibleRows = self.tableView.rows(in: self.tableView.visibleRect)
        for row in visibleRows.lowerBound..<visibleRows.upperBound {
            if let cellView = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CandidateTableCellView {
                self.configureCellView(cellView, forRow: row)
            }
        }
    }

    func getMaxTextWidth(candidates: some Sequence<String>, font: NSFont = CandidateWindowStyle.font) -> CGFloat {
        candidates.reduce(0) { maxWidth, candidate in
            let attributedString = NSAttributedString(
                string: candidate,
                attributes: [.font: font]
            )
            return max(maxWidth, ceil(attributedString.size().width))
        }
    }

    var numberOfVisibleRows: Int {
        self.candidates.count
    }

    /// From the window's left edge to where the candidates' text starts, which goes under the start of the text they
    /// are for
    var textOffset: CGFloat {
        CandidateWindowStyle.leadingInset
    }

    func getWindowWidth(maxContentWidth: CGFloat) -> CGFloat {
        max(CandidateWindowStyle.minimumWidth, self.textOffset + maxContentWidth + CandidateWindowStyle.trailingInset)
    }

    func resizeWindowToFitContent(lineRect: CGRect) {
        guard let window = self.view.window else {
            return
        }
        // window.screen returns the screen the window is on now. With multiple displays,
        // right after the cursor moves to another display, this can differ from the
        // display that holds the cursor. So always prefer the screen that contains the
        // text's line.
        guard let screen = ScreenLookup.screen(containing: lineRect.origin, fallbackWindow: window) else {
            return
        }

        if self.numberOfVisibleRows == 0 {
            return
        }

        let height = CGFloat(self.numberOfVisibleRows) * self.tableView.rowHeight + 2 * CandidateWindowStyle.verticalPadding
        let maxWidth = self.getMaxTextWidth(candidates: self.candidates.lazy.map { $0.candidate.text })
        let newWindowFrame = WindowPositioning.candidateWindowFrame(
            lineRect: .init(lineRect),
            textOffset: Double(self.textOffset),
            size: .init(width: Double(self.getWindowWidth(maxContentWidth: maxWidth)), height: Double(height)),
            screenRect: .init(screen.visibleFrame)
        ).cgRect
        if newWindowFrame != window.frame {
            window.setFrame(newWindowFrame, display: true, animate: false)
            // The shadow follows the rounded corners only when it is made again for the new size
            window.invalidateShadow()
        }
    }

    func getSelectedCandidate() -> Candidate? {
        guard currentSelectedRow >= 0 && currentSelectedRow < candidates.count else {
            return nil
        }
        return candidates[currentSelectedRow].candidate
    }

    func selectNextCandidate() {
        guard !candidates.isEmpty else {
            return
        }
        let nextRow = (currentSelectedRow + 1) % candidates.count
        updateSelection(to: nextRow)
    }

    func selectPrevCandidate() {
        guard !candidates.isEmpty else {
            return
        }
        let prevRow = (currentSelectedRow - 1 + candidates.count) % candidates.count
        updateSelection(to: prevRow)
    }

    internal func configureCellView(_ cell: CandidateTableCellView, forRow row: Int) {
        cell.candidateTextField.stringValue = candidates[row].candidate.text
        cell.showNumberColumn(false)
        cell.showCandidateAnnotationTextField(false)
        cell.candidateAnnotationTextField.stringValue = ""
        cell.applyColors(selected: row == self.currentSelectedRow)
    }
}

extension BaseCandidateViewController: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        candidates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellIdentifier = NSUserInterfaceItemIdentifier("CandidateCell")
        var cell = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? CandidateTableCellView

        if cell == nil {
            cell = CandidateTableCellView()
            cell?.identifier = cellIdentifier
        }

        if let cell = cell {
            configureCellView(cell, forRow: row)
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("CandidateRowView")
        var rowView = tableView.makeView(withIdentifier: identifier, owner: nil) as? CandidateTableRowView

        if rowView == nil {
            rowView = CandidateTableRowView()
            rowView?.identifier = identifier
        }

        return rowView
    }
}
