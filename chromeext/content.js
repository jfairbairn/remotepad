// alert("foo");
// console.log('loaded content.js');
(function(){
var idsUpdated = false;
var idNum = 0;
var isEmpty = function(o) {
  for(i in o) {
    if (o.hasOwnProperty(i)) return false;
  }
  return true;
};

var dispatchMouseEvent = function(target, var_args) {
  var e = document.createEvent("MouseEvents");
  // If you need clientX, clientY, etc., you can call
  // initMouseEvent instead of initEvent
  e.initEvent.apply(e, Array.prototype.slice.call(arguments, 1));
  target.dispatchEvent(e);
};

var reportScrollChanges = true;

var lastX = 0, lastY = 0;
chrome.extension.onRequest.addListener(function(req, sender, cb) {
  if (req.scroll) {
    reportScrollChanges = false;
    window.scrollTo(req.scroll[0], req.scroll[1])
    lastX = req.scroll[0];
    lastY = req.scroll[1];
    reportScrollChanges = true;
  }
  if (req.click) {
    var e = document.elementFromPoint(req.click[0], req.click[1]);
    dispatchMouseEvent(e, "click", true, true);
  }
  if (req.get) {
    var things = req.get;
    resp = {};
    if (!idsUpdated) {
      $("*").each(function(){
        var el = $(this);
        if (!el.attr("id")) {
          el.attr("id", "cmtv" + idNum++);
        }
      });
      idsUpdated = true;
    }
    for (i in things) {
      var thing = things[i];
      if (thing == 'height') {
        resp['height'] = document.body.scrollHeight;
      }
      if (thing == 'width') {
        resp['width'] = document.body.scrollWidth;
      }
      if (thing == 'url') {
        resp['url'] = window.location.href;
      }
      if (thing == 'scroll') {
        resp['scroll'] = [lastX, lastY];
      }
      if (thing == 'src') {
        resp['src'] = $("html").html();
        resp['url'] = window.location.href;
      }
    }
    if (!isEmpty(resp))
      port.postMessage(resp);
  }
});

var port = chrome.extension.connect();

var height = 0, width = 0;
setInterval(function() {
  if (height != document.body.scrollHeight || width != document.body.scrollWidth) {
    height = document.body.scrollHeight;
    width = document.body.scrollWidth;
    var msg = {height:height,width:width};
    port.postMessage(msg);
  }
}, 200);

setInterval(function() {
    offs = [];
    if (lastX != window.pageXOffset || lastY != window.pageYOffset) {
      lastX = window.pageXOffset;
      lastY = window.pageYOffset;
      offs[0] = lastX;
      offs[1] = lastY;
    }
    if (!isEmpty(offs) && reportScrollChanges) {
      port.postMessage({scroll:offs});
    }
}, 100);

})();