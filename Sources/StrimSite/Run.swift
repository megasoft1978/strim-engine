import Foundation

public struct SiteResult {
    public var exitCode: Int32
    public var html: String
    public var readme: String
    public var dataJSON: String
    public var errors: [String]
    /// Other generated files, keyed by repo-relative path (headline.json, chart SVGs, style.css).
    public var generated: [String: String] = [:]
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
        var generated: [String: String] = [:]
        H = try buildHeadline()
        F = try loadFeatures()
        generated["site/data/headline.json"] = PyJSONWriter.dumps(H) + "\n"
        for (name, svg) in chartAssets() { generated["site/assets/" + name] = svg + "\n" }
        for (rel, svg) in readmeAssets() { generated[rel] = svg + "\n" }
        let htmlText = buildLandingHTML()
        let benchText = buildBenchmarksHTML()
        if let failure { throw SiteError(failure) }
        generated["site/benchmarks.html"] = benchText
        generated["site/assets/site.js"] = SITE_JS
        let cssPath = "site/assets/style.css"
        generated[cssPath] = styleWithChartBlock(readText(root + "/" + cssPath) ?? "")
        for (rel, content) in generated.sorted(by: { $0.key < $1.key }) {
            let old = readText(root + "/" + rel)
            if old != content {
                if opts.check { syncErr.append("\(rel) is out of sync (run strim site build)") } else {
                    try? FileManager.default.createDirectory(atPath: (root + "/" + rel as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try write(root + "/" + rel, content)
                }
            }
        }
        let readme = try buildReadme()
        if !opts.check {
            try write(outHTML, htmlText)
            try write(outReadme, readme)
            log("wrote site/index.html (\(htmlText.unicodeScalars.count) bytes), site/benchmarks.html (\(benchText.unicodeScalars.count) bytes) and README.md")
        }
        var errs = syncErr + (try checkFigures())
        for (rel, content) in generated where rel.hasSuffix(".svg") || rel.hasSuffix(".css") { let g = greenColours(in: content); if !g.isEmpty { errs.append("\(rel) uses green colours: \(g.prefix(5).joined(separator: ", "))") } }
        let (he, nl) = checkHTML(htmlText)
        errs += he
        let (be, bl) = checkHTML(benchText)
        errs += be.map { "benchmarks.html: " + $0 }
        errs += checkCrossAnchors(landing: htmlText, benchmarks: benchText)
        errs += checkReadmeShape(readme)
        errs += checkMarkdownLinks(readme, base: root)
        let pend = D.order.filter { D.pending($0) }
        log("figures: \(D.figs.count)  pending: \(pend.count)  html links checked: \(nl + bl)")
        let sc = soakComplete()
        log("final dataset: \(finalState()) | complete soak: \(sc.map { String($0.split(separator: "/").last ?? "") } ?? "none")")
        for e in errs { log("ERROR \(e)") }
        if let failure { throw SiteError(failure) }
        return SiteResult(exitCode: errs.isEmpty ? 0 : 1, html: htmlText, readme: readme, dataJSON: newText, errors: errs, generated: generated)
    }
}

extension SiteBuilder {
    /// style.css with the generated chart block (between the hv markers) replaced, or appended when absent.
    func styleWithChartBlock(_ css: String) -> String {
        let block = HV_BEGIN + "\n" + hvCSSPage() + "\n" + HV_END
        if let b = css.range(of: HV_BEGIN), let e = css.range(of: HV_END, range: b.upperBound..<css.endIndex) {
            return String(css[..<b.lowerBound]) + block + String(css[e.upperBound...])
        }
        return css + (css.hasSuffix("\n") || css.isEmpty ? "" : "\n") + block + "\n"
    }
}
