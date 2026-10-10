import Foundation

/// JavaScript the WebShell injects at document start in every frame (spec §5). The sources are Swift constants because
/// a shortcut bundle carries no resource files. The page controls every string it posts, so the native side validates
/// each message and never interpolates page text into JavaScript; `notificationClickedScript(id:)` takes a `UUID`
/// for that reason.
public enum WebShellScripts {
    /// `WKScriptMessageHandler` name that receives badge updates.
    public static let badgeHandlerName = "madBadge"
    /// `WKScriptMessageHandler` name that receives notification show and close messages.
    public static let notificationHandlerName = "madNotification"
    /// Global function the shell calls when the user clicks a delivered notification.
    public static let notificationClickedFunctionName = "__madNotificationClicked"

    /// The statement the shell evaluates after a notification click. `id` is lower-cased to match the ids that
    /// `crypto.randomUUID()` produces.
    public static func notificationClickedScript(id: UUID) -> String {
        "window.\(notificationClickedFunctionName)(\"\(id.uuidString.lowercased())\")"
    }

    /// Replaces `navigator.setAppBadge(n)` and `navigator.clearAppBadge()` with posts to `madBadge`:
    /// `{count: n}` for a positive whole number, `{}` (clear) for everything else.
    public static let badgeBridge = #"""
    (function () {
      'use strict';
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.madBadge;
      if (!handler) { return; }
      function post(message) {
        try { handler.postMessage(message); } catch (error) { /* the native side is gone; nothing to report to */ }
      }
      function setAppBadge(contents) {
        var count = Math.floor(Number(contents));
        post(isFinite(count) && count > 0 ? { count: count } : {});
        return Promise.resolve();
      }
      function clearAppBadge() {
        post({});
        return Promise.resolve();
      }
      Object.defineProperty(navigator, 'setAppBadge', { value: setAppBadge, configurable: true, writable: true });
      Object.defineProperty(navigator, 'clearAppBadge', { value: clearAppBadge, configurable: true, writable: true });
    })();
    """#

    /// Replaces `window.Notification` with a shim that posts `{id, title, body, tag}` to `madNotification`
    /// (`{id, close: true}` on `close()`), reports permission `"granted"` and dispatches `click` when the shell calls
    /// `window.__madNotificationClicked(id)`. Ids come from `crypto.randomUUID()`.
    public static let notificationShim = #"""
    (function () {
      'use strict';
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.madNotification;
      if (!handler || window.__madNotificationShim) { return; }
      window.__madNotificationShim = true;

      var MAX_TRACKED = 100;
      var registry = new Map();

      function post(message) {
        try { handler.postMessage(message); } catch (error) { /* the native side is gone; nothing to report to */ }
      }

      function newId() {
        if (typeof crypto.randomUUID === 'function') { return crypto.randomUUID(); }
        var bytes = crypto.getRandomValues(new Uint8Array(16));
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        var hex = Array.prototype.map.call(bytes, function (byte) { return (byte + 256).toString(16).slice(1); }).join('');
        return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
      }

      function text(value) {
        return value === undefined || value === null ? '' : String(value);
      }

      class MADNotification {
        constructor(title, options) {
          var settings = options || {};
          this.title = text(title);
          this.body = text(settings.body);
          this.tag = text(settings.tag);
          this.icon = text(settings.icon);
          this.data = settings.data === undefined ? null : settings.data;
          this.silent = settings.silent === true;
          this.onclick = null;
          this.onclose = null;
          this.onerror = null;
          this.onshow = null;
          this._listeners = {};
          this._id = newId().toLowerCase();
          registry.set(this._id, this);
          if (registry.size > MAX_TRACKED) { registry.delete(registry.keys().next().value); }
          post({ id: this._id, title: this.title, body: this.body, tag: this.tag });
        }

        static get permission() { return 'granted'; }

        static requestPermission(callback) {
          if (typeof callback === 'function') { callback('granted'); }
          return Promise.resolve('granted');
        }

        static get maxActions() { return 0; }

        addEventListener(type, listener) {
          if (typeof listener !== 'function') { return; }
          var list = this._listeners[type] || (this._listeners[type] = []);
          if (list.indexOf(listener) === -1) { list.push(listener); }
        }

        removeEventListener(type, listener) {
          var list = this._listeners[type];
          if (!list) { return; }
          var index = list.indexOf(listener);
          if (index !== -1) { list.splice(index, 1); }
        }

        dispatchEvent(event) {
          var handlerProperty = this['on' + event.type];
          if (typeof handlerProperty === 'function') { handlerProperty.call(this, event); }
          var list = (this._listeners[event.type] || []).slice();
          for (var index = 0; index < list.length; index++) { list[index].call(this, event); }
          return true;
        }

        close() {
          if (!registry.delete(this._id)) { return; }
          post({ id: this._id, close: true });
          this.dispatchEvent({ type: 'close', target: this, currentTarget: this, preventDefault: function () {} });
        }
      }

      Object.defineProperty(window, 'Notification', { value: MADNotification, configurable: true, writable: true });

      window.__madNotificationClicked = function (id) {
        var notification = registry.get(String(id).toLowerCase());
        if (!notification) { return false; }
        notification.dispatchEvent({ type: 'click', target: notification, currentTarget: notification, preventDefault: function () {} });
        return true;
      };
    })();
    """#
}
