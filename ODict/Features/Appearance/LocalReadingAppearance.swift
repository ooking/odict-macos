import Foundation

/// Document-scoped CSSOM edits remove only global font declarations, including
/// !important. Specific rules remain in the cascade unchanged. No element walk,
/// polling, observer, file writes, or cross-document state is required.
enum LocalReadingAppearance {
    static func script(css: String, pageURL: URL?) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [css, pageURL?.absoluteString ?? ""]) else { return "" }
        let literal = String(decoding: data, as: UTF8.self)
        return #"""
        (() => {
          const [css, page] = \#(literal);
          if (location.href.split('#')[0] !== page || !document.body) return;
          const key = '__odictGlobalReadingFontsV1';
          const styleID = 'odict-reading-appearance';
          const properties = ['font-family', 'font-size'];
          let state = window[key];

          function remember(style) {
            return properties.map(name => [name, style.getPropertyValue(name), style.getPropertyPriority(name)]);
          }
          function restore(style, values) {
            for (const [name, value, priority] of values) {
              if (value) style.setProperty(name, value, priority);
              else style.removeProperty(name);
            }
          }
          function splitSelectors(text) {
            const parts = [];
            let start = 0, depth = 0, quote = '', escaped = false;
            for (let index = 0; index < text.length; index++) {
              const character = text[index];
              if (escaped) { escaped = false; continue; }
              if (character === '\\') { escaped = true; continue; }
              if (quote) { if (character === quote) quote = ''; continue; }
              if (character === '"' || character === "'") { quote = character; continue; }
              if (character === '(' || character === '[') depth++;
              if (character === ')' || character === ']') depth--;
              if (character === ',' && depth === 0) {
                parts.push(text.slice(start, index).trim()); start = index + 1;
              }
            }
            parts.push(text.slice(start).trim());
            return parts;
          }
          function globalSelector(selector) {
            selector = selector.replace(/\/\*[\s\S]*?\*\//g, '').trim().toLowerCase();
            const group = selector.match(/^:(?:where|is)\((.*)\)$/);
            if (group) return splitSelectors(group[1]).every(globalSelector);
            // A deliberately narrow definition: classes, IDs, attributes,
            // pseudo-elements, and tags such as p/span are independent styles.
            return /^(?:html|body|:root|\*)(?:(?:\s*>\s*|\s+)(?:html|body|:root|\*))*$/.test(selector);
          }

          if (!css) {
            if (state) {
              for (const edit of state.edits.reverse()) {
                try {
                  if (edit.extra) {
                    const index = Array.from(edit.parent.cssRules).indexOf(edit.extra);
                    if (index >= 0) edit.parent.deleteRule(index);
                  }
                  edit.rule.selectorText = edit.selector;
                  restore(edit.rule.style, edit.values);
                } catch (_) { /* A dictionary script may have removed a rule. */ }
              }
              for (const edit of state.inline) restore(edit.element.style, edit.values);
              delete window[key];
            }
            document.getElementById(styleID)?.remove();
            return;
          }

          if (!state) {
            state = { edits: [], inline: [] };
            window[key] = state;
            const visitedSheets = new Set();
            let remaining = 16384;
            function walk(parent) {
              let rules;
              try { rules = Array.from(parent.cssRules); } catch (_) { return; }
              for (const rule of rules) {
                // Bounds apply per document, and state disappears with its page.
                if (--remaining < 0 || state.edits.length >= 2048) return;
                if (rule.type === 3 && rule.styleSheet) { sheet(rule.styleSheet); continue; }
                if (rule.type !== 1) { if (rule.cssRules) walk(rule); continue; }
                if (!properties.some(name => rule.style.getPropertyValue(name))) continue;
                const selectors = splitSelectors(rule.selectorText);
                const globals = selectors.filter(globalSelector);
                if (!globals.length) continue;
                const specifics = selectors.filter(selector => !globalSelector(selector));
                const edit = { parent, rule, selector: rule.selectorText, values: remember(rule.style), extra: null };
                try {
                  // Split mixed lists so `body, .phonetic { font: ... }`
                  // changes body while preserving .phonetic's complete style.
                  if (specifics.length) {
                    const index = Array.from(parent.cssRules).indexOf(rule);
                    parent.insertRule(specifics.join(',') + '{' + rule.style.cssText + '}', index + 1);
                    edit.extra = parent.cssRules[index + 1];
                    rule.selectorText = globals.join(',');
                  }
                  state.edits.push(edit);
                  for (const name of properties) rule.style.removeProperty(name);
                } catch (_) {
                  // Leave unsupported/read-only rules intact, including any
                  // independent selector, rather than broadening the override.
                  if (edit.extra) {
                    const index = Array.from(parent.cssRules).indexOf(edit.extra);
                    if (index >= 0) parent.deleteRule(index);
                  }
                  rule.selectorText = edit.selector;
                }
              }
            }
            function sheet(value) {
              if (visitedSheets.has(value) || value.ownerNode?.id === styleID) return;
              visitedSheets.add(value); walk(value);
            }
            for (const value of Array.from(document.styleSheets)) sheet(value);
            // Inline !important on html/body would beat a stylesheet rule.
            // Remove only these two properties and restore them when disabled.
            for (const element of [document.documentElement, document.body]) {
              state.inline.push({ element, values: remember(element.style) });
              for (const name of properties) element.style.removeProperty(name);
            }
          }
          let style = document.getElementById(styleID);
          if (!style) {
            style = document.createElement('style'); style.id = styleID;
            document.body.appendChild(style);
          }
          style.textContent = css;
        })();
        """#
    }
}
