import Cocoa
import Core
import KanaKanjiConverterModule

protocol CandidatesViewControllerDelegate: AnyObject {
    func candidateSubmitted()
    func candidateSelectionChanged(_ row: Int)
}

class CandidatesViewController: BaseCandidateViewController {
    weak var delegate: (any CandidatesViewControllerDelegate)?
    private var showedRows: ClosedRange = 0...8
    var showCandidateIndex = false

    override func updateCandidatePresentations(_ candidates: [CandidatePresentation], selectionIndex: Int?, lineRect: CGRect) {
        self.showedRows = selectionIndex == nil ? 0...8 : self.showedRows
        super.updateCandidatePresentations(
            candidates,
            selectionIndex: selectionIndex,
            lineRect: lineRect
        )
    }

    override internal func updateSelectionCallback(_ row: Int, notifySelectionChange: Bool) {
        if notifySelectionChange {
            delegate?.candidateSelectionChanged(row)
        }

        if !self.showedRows.contains(row) {
            if row < self.showedRows.lowerBound {
                self.showedRows = row...(row + 8)
            } else {
                self.showedRows = (row - 8)...row
            }
        }
    }

    override internal func configureCellView(_ cell: CandidateTableCellView, forRow row: Int) {
        let annotationText = self.candidates[row].displayContext.annotationText
        cell.candidateTextField.stringValue = self.candidates[row].candidate.text
        // The rows the number keys choose (see `getNumberCandidate`) have their numbers; the others leave the column
        // empty, so the text of all rows starts at the same place
        cell.showNumberColumn(self.showCandidateIndex)
        cell.numberTextField.stringValue = self.showedRows.contains(row) ? "\(row - self.showedRows.lowerBound + 1)" : ""
        if let annotationText {
            cell.showCandidateAnnotationTextField(true)
            cell.candidateAnnotationTextField.stringValue = annotationText
        } else {
            cell.showCandidateAnnotationTextField(false)
            cell.candidateAnnotationTextField.stringValue = ""
        }
        cell.applyColors(selected: row == self.currentSelectedRow)
    }

    func getNumberCandidate(num: Int) -> Int {
        let nextRow = self.showedRows.lowerBound + num - 1
        return nextRow
    }

    func hide() {
        self.currentSelectedRow = -1
        self.showedRows = 0...8
    }

    override var numberOfVisibleRows: Int {
        min(9, self.tableView.numberOfRows)
    }

    override var textOffset: CGFloat {
        CandidateWindowStyle.leadingInset + (self.showCandidateIndex ? CandidateWindowStyle.numberColumnWidth : 0)
    }

    override func getWindowWidth(maxContentWidth: CGFloat) -> CGFloat {
        let annotations = self.candidates.compactMap(\.displayContext.annotationText)
        let annotationWidth = annotations.isEmpty
            ? 0
            : CandidateWindowStyle.annotationGap + self.getMaxTextWidth(candidates: annotations, font: CandidateWindowStyle.annotationFont)
        return super.getWindowWidth(maxContentWidth: maxContentWidth + annotationWidth)
    }
}

class PredictionCandidatesViewController: BaseCandidateViewController {
    private let prefixTabStop: CGFloat = 24
    private let prefixSymbolName = "arrow.forward.to.line.compact"
    private let prefixFontSize: CGFloat = 12

    override var numberOfVisibleRows: Int {
        min(3, self.tableView.numberOfRows)
    }

    override internal func configureCellView(_ cell: CandidateTableCellView, forRow row: Int) {
        let candidateText = candidates[row].candidate.text
        let attributedString = NSMutableAttributedString()

        let isSelected = currentSelectedRow == row
        let candidateColor = isSelected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor

        if let symbol = NSImage(systemSymbolName: prefixSymbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: prefixFontSize, weight: .regular)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let attachment = NSTextAttachment()
            attachment.image = configured
            attachment.bounds = NSRect(x: 0, y: -2, width: prefixFontSize + 2, height: prefixFontSize + 2)
            attributedString.append(NSAttributedString(attachment: attachment))
        }
        attributedString.append(NSAttributedString(string: "\t"))
        let candidateAttributed = NSAttributedString(
            string: candidateText,
            attributes: [
                .font: CandidateWindowStyle.font,
                .foregroundColor: candidateColor
            ]
        )
        attributedString.append(candidateAttributed)

        let fullRange = NSRange(location: 0, length: attributedString.length)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: prefixTabStop, options: [:])
        ]
        paragraphStyle.defaultTabInterval = prefixTabStop
        attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        cell.showNumberColumn(false)
        cell.showCandidateAnnotationTextField(false)
        cell.candidateTextField.attributedStringValue = attributedString
    }

    // The arrow goes before the text, so the text starts one tab stop further in
    override var textOffset: CGFloat {
        CandidateWindowStyle.leadingInset + self.prefixTabStop
    }
}
