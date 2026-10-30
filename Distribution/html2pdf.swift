// Renders an HTML file to an A4 PDF: swift html2pdf.swift in.html out.pdf
import AppKit

let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

let html = try Data(contentsOf: input)
guard let text = NSAttributedString(html: html, baseURL: input.deletingLastPathComponent(), documentAttributes: nil) else {
    fatalError("could not read \(input.path)")
}

let page = NSSize(width: 595, height: 842)
let margin: CGFloat = 54
let view = NSTextView(frame: NSRect(x: 0, y: 0, width: page.width - 2 * margin, height: page.height))
view.textStorage?.setAttributedString(text)
view.sizeToFit()

let info = NSPrintInfo()
info.paperSize = page
info.topMargin = margin
info.bottomMargin = margin
info.leftMargin = margin
info.rightMargin = margin
info.horizontalPagination = .fit
info.verticalPagination = .automatic
info.jobDisposition = .save
info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

let op = NSPrintOperation(view: view, printInfo: info)
op.showsPrintPanel = false
op.showsProgressPanel = false
op.run()
