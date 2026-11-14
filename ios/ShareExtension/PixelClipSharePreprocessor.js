// Safari runs this in the page when PixelClip Reader is chosen in the share sheet: the page's URL, title,
// HTML (the app extracts the article from it) and the visible text of its main element (for the
// sheet's word count).
var PixelClipSharePreprocessor = function() {};
PixelClipSharePreprocessor.prototype = {
    run: function(args) {
        var main = document.querySelector("article") || document.querySelector("main") || document.body;
        var html = document.documentElement ? document.documentElement.outerHTML : "";
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
