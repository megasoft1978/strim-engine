import Foundation

// Shared page shell of index.html and benchmarks.html: head and meta tags, header, footer, the small script (copy buttons, theme toggle).

extension SiteBuilder {
    func pageHead(title: String, desc: String, path: String, bodyClass: String) -> String {
        let url = SITE_URL + path
        let img = SITE_URL + "assets/og-image.png"
        return """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>\(esc(title))</title>
<meta name="description" content="\(esc(desc))">
<meta name="color-scheme" content="dark light">
<meta name="theme-color" content="#0C0D10" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#FAFAFB" media="(prefers-color-scheme: light)">
<link rel="canonical" href="\(url)">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Strim">
<meta property="og:title" content="\(esc(title))">
<meta property="og:description" content="\(esc(desc))">
<meta property="og:url" content="\(url)">
<meta property="og:image" content="\(img)">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="\(esc(bannerAlt()))">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="\(esc(title))">
<meta name="twitter:description" content="\(esc(desc))">
<meta name="twitter:image" content="\(img)">
<link rel="icon" href="assets/favicon.svg" type="image/svg+xml">
<link rel="icon" href="assets/favicon-32.png" type="image/png" sizes="32x32">
<link rel="apple-touch-icon" href="assets/apple-touch-icon.png">
<link rel="preload" href="assets/fonts/space-grotesk-var.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="assets/fonts/jetbrains-mono-var.woff2" as="font" type="font/woff2" crossorigin>
<script>try{var t=localStorage.getItem('strim-theme');if(t==='light'||t==='dark')document.documentElement.setAttribute('data-theme',t)}catch(e){}</script>
<link rel="stylesheet" href="assets/style.css">
</head>
<body class="\(bodyClass)">
"""
    }

    /// Sticky solid navigation. `links` are (label, href); `sub` is a second row of in-page links below the bar.
    func headerHTML(_ links: [(String, String)], brandHref: String, sub: [(String, String)] = [], cta: Bool = true) -> String {
        var o = "<a class=\"skip\" href=\"#main\">Skip to content</a>\n<header class=\"site\"><div class=\"wrap\"><div class=\"hbar\">"
        o += "<a class=\"brand\" href=\"\(brandHref)\">\(markSVG("hb", standalone: false, title: ""))\(wordmarkSVG())<span class=\"sr\">Strim</span></a>"
        o += "<nav aria-label=\"Sections\"><ul>" + links.map { "<li><a href=\"\($0.1)\">\(esc($0.0))</a></li>" }.joined() + "</ul></nav>"
        o += "<div class=\"hact\"><a class=\"gh\" href=\"\(REPO_URL)\" aria-label=\"Strim on GitHub\" title=\"GitHub\"><svg viewBox=\"0 0 16 16\" width=\"18\" height=\"18\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z\"/></svg></a>"
        o += "<button type=\"button\" class=\"theme\" id=\"theme\" aria-label=\"Switch between dark and light\" title=\"Switch theme\" hidden><svg viewBox=\"0 0 24 24\" width=\"18\" height=\"18\" aria-hidden=\"true\"><circle cx=\"12\" cy=\"12\" r=\"4\"/><path d=\"M12 2v2m0 16v2M4.93 4.93l1.42 1.42m11.3 11.3 1.42 1.42M2 12h2m16 0h2M4.93 19.07l1.42-1.42m11.3-11.3 1.42-1.42\"/></svg></button>"
        if cta { o += "<a class=\"btn nav-cta\" href=\"\(REPO_URL)/releases/latest\">Download for Mac</a>" }
        o += "</div></div></div></header>\n"
        if !sub.isEmpty {
            o += "<div class=\"wrap\"><nav class=\"subnav\" aria-label=\"On this page\"><ul>" + sub.map { "<li><a href=\"\($0.1)\">\(esc($0.0))</a></li>" }.joined() + "</ul></nav></div>\n"
        }
        return o
    }

    /// Footer with logo, link columns, the non-affiliation line and the data provenance (run id and date, which are data, so the page stays reproducible).
    func footerHTML() -> String {
        let run = H["run"]?["date"]?.pyStr ?? ""
        func col(_ title: String, _ items: [(String, String)]) -> String {
            "<div class=\"fc\"><h2>\(title)</h2><ul>" + items.map { "<li><a href=\"\($0.1)\">\(esc($0.0))</a></li>" }.joined() + "</ul></div>"
        }
        var o = "<footer><div class=\"wrap\"><div class=\"fgrid\"><div class=\"fb\"><a class=\"brand\" href=\"index.html\">\(markSVG("fb", standalone: false, title: ""))\(wordmarkSVG())<span class=\"sr\">Strim</span></a>"
        o += "<p>The local model server built for coding agents. One Swift binary, MIT.</p></div>"
        o += col("Project", [("GitHub", REPO_URL), ("Releases", REPO_URL + "/releases"), ("License", "../LICENSE")])
        o += col("Read", [("Benchmarks", "benchmarks.html"), ("Install", "../docs/INSTALL.md"), ("Data", "data/headline.json")])
        o += "</div><p class=\"fine\">Not affiliated with Qwen, Alibaba or Apple. Model and platform names belong to their owners.</p>"
        let build = H["run"]?["strim_build"]?.pyStr ?? ""
        o += "<p class=\"stamp\">Numbers last measured \(esc(run)) on build <a href=\"\(REPO_URL)/commit/\(esc(build))\">\(esc(build))</a> &middot; <a href=\"../\(esc(FINAL_REL))/results.json\">Raw data</a></p>"
        o += "</div></footer>\n" + siteScript
        return o
    }

    /// The page script lives in assets/site.js (SITE_JS); it has no inline code so the page needs no unsafe-inline script policy.
    var siteScript: String { "<script src=\"assets/site.js\" defer></script>\n</body>\n</html>\n" }
}
