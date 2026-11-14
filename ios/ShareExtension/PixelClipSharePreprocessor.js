// Safari runs this in the page when PixelClip Reader is chosen in the share sheet: the page's URL, title,
// HTML (the app extracts the article from it) and the visible text of its main element (for the
// sheet's word count).
//
// The HTML is a copy of the page without what the Reader never reads and has no business keeping until
// the app is next opened: scripts (and the data, tokens and state pages put in them), styles, frames,
// form fields and comments. If the copy can't be made, the page goes as it is, as before.
var PixelClipSharePreprocessor = function() {};
PixelClipSharePreprocessor.prototype = {
    pageHTML: function() {
        if (!document.documentElement) { return ""; }
        try {
            var copy = document.documentElement.cloneNode(true);
            var drop = copy.querySelectorAll("script, style, noscript, template, iframe, object, embed, link, input, textarea, select, svg, canvas");
            for (var i = 0; i < drop.length; i++) { drop[i].remove(); }
            var walker = document.createTreeWalker(copy, NodeFilter.SHOW_COMMENT, null);
            var comments = [];
            while (walker.nextNode()) { comments.push(walker.currentNode); }
            for (var j = 0; j < comments.length; j++) { comments[j].remove(); }
            return copy.outerHTML;
        } catch (e) {
            return document.documentElement.outerHTML;
        }
    },
    run: function(args) {
        var main = document.querySelector("article") || document.querySelector("main") || document.body;
        var html = this.pageHTML();
        if (html.length > 4000000) { html = ""; }
        args.completionFunction({
            "url": document.URL,
            "title": document.title,
            "html": html,
            "text": main ? main.innerText : ""
        });
    },
    finalize: function(args) {}
};
var ExtensionPreprocessingJS = new PixelClipSharePreprocessor;
