import Foundation

public struct SiteResult {
    public var exitCode: Int32
    public var html: String
    public var readme: String
    public var dataJSON: String
    public var errors: [String]
}

extension SiteBuilder {
    /// Main entry (as the retired Python script did). Throws SiteError for the conditions where Python exits via SystemExit / crashes.
    @discardableResult
    public func run(_ opts: SiteOptions) throws -> SiteResult {
        failure = nil
        if opts.refreshSoak { try refreshSoak() }
        guard let oldText = SafeIO.readRegular(root: root, path: dataPath, allowSymlinks: allowSymlinkedTree) else { throw SiteError("cannot read site/data/results.json") }
        let raw = try syncFinal(try PyJSONParser.parse(oldText))
        let newText = PyJSONWriter.dumps(raw) + "\n"
        var syncErr: [String] = []
        if newText != oldText {
            if opts.check {
                syncErr.append("site/data/results.json is out of sync with \(FINAL_REL) (run strim site build)")
            } else {
                try write(dataPath, newText)
                log("regenerated final.* figures in site/data/results.json")
            }
        }
        D = try SiteData(raw: raw)
        if opts.listFigures {
            for i in D.order {
                let f = D.figs[i]!
                log("\(i)\t\(D.text(i))\t\(f.unitJSON.pyStr)\t\(f.sourcePath)")
            }
            return SiteResult(exitCode: 0, html: "", readme: "", dataJSON: newText, errors: [])
        }
        let htmlText = buildHTML()
        if let failure { throw SiteError(failure) }
        let readme = try buildReadme()
        if !opts.check {
            try write(outHTML, htmlText)
            try write(outReadme, readme)
            log("wrote site/index.html (\(htmlText.unicodeScalars.count) bytes) and README.md")
        }
        var errs = syncErr + (try checkFigures())
        let (he, nl) = checkHTML(htmlText)
        errs += he
        errs += checkMarkdownLinks(readme, base: root)
        let pend = D.order.filter { D.pending($0) }
        log("figures: \(D.figs.count)  pending: \(pend.count)  html links checked: \(nl)")
        let sc = soakComplete()
        log("final dataset: \(finalState()) | complete soak: \(sc.map { String($0.split(separator: "/").last ?? "") } ?? "none")")
        for e in errs { log("ERROR \(e)") }
        if let failure { throw SiteError(failure) }
        return SiteResult(exitCode: errs.isEmpty ? 0 : 1, html: htmlText, readme: readme, dataJSON: newText, errors: errs)
    }
}
