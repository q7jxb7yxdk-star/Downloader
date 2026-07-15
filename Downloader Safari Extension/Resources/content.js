const downloadableExtensions = new Set([
  "7z", "aac", "avi", "bin", "bz2", "csv", "dmg", "doc", "docx", "epub",
  "exe", "flac", "gif", "gz", "iso", "jpeg", "jpg", "m4a", "m4v", "mkv",
  "mov", "mp3", "mp4", "msi", "pdf", "pkg", "png", "ppt", "pptx", "rar",
  "tar", "torrent", "tsv", "txt", "wav", "webm", "webp", "xls", "xlsx",
  "xz", "zip"
]);

let automaticallyCaptureDownloads = true;
const pendingProbes = new Map();
const capturedPageURLs = new Map();
const pageCaptureWindow = 3000;

requestAutoCaptureSetting();
captureCurrentLocationIfDownload();

window.addEventListener("focus", () => {
  requestAutoCaptureSetting();
  captureCurrentLocationIfDownload();
});

window.addEventListener("pageshow", () => {
  captureCurrentLocationIfDownload();
});

document.addEventListener("click", (event) => {
  if (!automaticallyCaptureDownloads || event.defaultPrevented || event.button !== 0) {
    return;
  }

  const request = downloadRequest(event);
  if (!request) {
    return;
  }

  event.preventDefault();
  event.stopPropagation();

  if (request.kind === "probe") {
    const requestID = createRequestID();
    const timeoutID = setTimeout(() => {
      const pending = pendingProbes.get(requestID);
      if (!pending) {
        return;
      }
      pendingProbes.delete(requestID);
      window.location.assign(pending.url);
    }, 12000);
    pendingProbes.set(requestID, {
      url: request.url,
      timeoutID
    });
    dispatchToExtension("probe-download", {
      requestID,
      url: request.url
    });
    return;
  }

  dispatchToExtension("auto-capture-download", {
    url: request.url,
    kind: request.kind,
    displayName: downloadableFileNameFromURL(new URL(request.url))
  });
}, true);

function dispatchToExtension(name, message) {
  return browser.runtime.sendMessage({
    name,
    ...(message || {})
  }).then((response) => {
    handleExtensionResponse(name, response);
    return response;
  }).catch((error) => {
    console.error("Downloader Safari Extension:", error);
    return null;
  });
}

function requestAutoCaptureSetting() {
  dispatchToExtension("request-auto-capture-setting");
}

function handleExtensionResponse(name, response) {
  if (!response) {
    return;
  }

  if (name === "request-auto-capture-setting" && typeof response.enabled === "boolean") {
    automaticallyCaptureDownloads = response.enabled;
    captureCurrentLocationIfDownload();
    return;
  }

  if (name !== "probe-download") {
    return;
  }

  const requestID = response.requestID;
  const pending = requestID ? pendingProbes.get(requestID) : null;
  if (!pending) {
    return;
  }

  pendingProbes.delete(requestID);
  clearTimeout(pending.timeoutID);
  if (response.isTorrent !== true) {
    window.location.assign(pending.url);
  }
}

function closestLink(event) {
  for (const node of event.composedPath()) {
    if (node instanceof HTMLAnchorElement && node.href) {
      return node;
    }
    if (node instanceof Element) {
      const link = node.closest("a[href]");
      if (link) {
        return link;
      }
    }
  }
  return null;
}

function downloadRequest(event) {
  const link = closestLink(event);
  if (link) {
    const url = normalizedURL(link.href);
    if (!url) {
      return null;
    }

    if (torrentURLPattern(url)) {
      return {
        url: url.href,
        kind: "torrent"
      };
    }

    if (link.hasAttribute("download") || isKnownDownloadURL(url)) {
      return {
        url: url.href,
        kind: null
      };
    }

    // A link label such as "torrent download" is only a hint. Some sites use
    // an HTML landing page whose URL and text look like a torrent download.
    // Probe the response before handing it to Downloader.
    if (isTorrentElement(link) || isProbableDownloadEndpoint(url)) {
      return {
        url: url.href,
        kind: "probe"
      };
    }
  }

  const actionable = closestActionableElement(event);
  if (!actionable || !isTorrentElement(actionable)) {
    return null;
  }

  const url = actionableURL(actionable);
  if (!url) {
    return null;
  }

  if (torrentURLPattern(url)) {
    return {
      url: url.href,
      kind: "torrent"
    };
  }

  return {
    url: url.href,
    kind: "probe"
  };
}

function closestActionableElement(event) {
  for (const node of event.composedPath()) {
    if (!(node instanceof Element)) {
      continue;
    }

    if (node.matches("button, input[type='button'], input[type='submit'], [role='button']")) {
      return node;
    }

    const actionable = node.closest(
      "button, input[type='button'], input[type='submit'], [role='button']"
    );
    if (actionable) {
      return actionable;
    }
  }
  return null;
}

function actionableURL(element) {
  const candidates = [
    element.getAttribute("formaction"),
    element.getAttribute("data-download-url"),
    element.getAttribute("data-url"),
    element.getAttribute("data-href"),
    element.closest("form[action]")?.action
  ];

  for (const candidate of candidates) {
    const url = normalizedURL(candidate);
    if (url) {
      return url;
    }
  }
  return null;
}

function isTorrentElement(element, url = null) {
  if (url && torrentURLPattern(url)) {
    return true;
  }

  const indicators = [
    element.getAttribute("download"),
    element.getAttribute("type"),
    element.getAttribute("data-type"),
    element.getAttribute("data-filetype"),
    element.getAttribute("data-filename"),
    element.getAttribute("title"),
    element.getAttribute("aria-label"),
    element instanceof HTMLInputElement ? element.value : null,
    element.textContent
  ].filter(Boolean).join(" ");

  return /application\/x-bittorrent/i.test(indicators)
    || /(^|[\s._-])torrent($|[\s._-])/i.test(indicators);
}

function isKnownDownloadURL(url) {
  if (url.protocol === "magnet:") {
    return true;
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return false;
  }

  const fileName = url.pathname.split("/").pop() || "";
  const extension = fileName.includes(".") ? fileName.split(".").pop().toLowerCase() : "";
  return downloadableExtensions.has(extension) || downloadableFileNameFromQuery(url) !== null;
}

function torrentURLPattern(url) {
  return url.protocol === "magnet:"
    || /\.torrent(?:$|[?#])/i.test(url.href);
}

function isProbableDownloadEndpoint(url) {
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return false;
  }

  return /(^|\/)(file|download)(\/|$)/i.test(url.pathname);
}

function createRequestID() {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function normalizedURL(value) {
  if (!value) {
    return null;
  }

  try {
    const url = new URL(value, document.baseURI);
    return ["http:", "https:", "magnet:"].includes(url.protocol) ? url : null;
  } catch {
    return null;
  }
}

function captureCurrentLocationIfDownload() {
  if (!automaticallyCaptureDownloads) {
    return;
  }

  const url = normalizedURL(window.location.href);
  if (!url || !isKnownDownloadURL(url)) {
    return;
  }

  if (!shouldCapturePageURL(url.href)) {
    return;
  }

  dispatchToExtension("auto-capture-download", {
    url: url.href,
    kind: torrentURLPattern(url) ? "torrent" : null,
    displayName: downloadableFileNameFromURL(url)
  });
}

function shouldCapturePageURL(url) {
  const now = Date.now();
  for (const [capturedURL, capturedAt] of capturedPageURLs.entries()) {
    if (now - capturedAt >= pageCaptureWindow) {
      capturedPageURLs.delete(capturedURL);
    }
  }

  const capturedAt = capturedPageURLs.get(url);
  if (capturedAt && now - capturedAt < pageCaptureWindow) {
    return false;
  }

  capturedPageURLs.set(url, now);
  return true;
}

function downloadableFileNameFromQuery(url) {
  const candidates = [];
  for (const [key, value] of url.searchParams.entries()) {
    const lowerKey = key.toLowerCase();
    if (
      lowerKey.includes("filename")
      || lowerKey === "response-content-disposition"
      || lowerKey === "rscd"
      || lowerKey === "content-disposition"
    ) {
      candidates.push(value);
    }
  }

  for (const candidate of candidates) {
    const fileName = fileNameFromDisposition(candidate) || fileNameFromValue(candidate);
    if (fileName && hasDownloadableExtension(fileName)) {
      return fileName;
    }
  }
  return null;
}

function downloadableFileNameFromURL(url) {
  return downloadableFileNameFromQuery(url) || fileNameFromValue(url.pathname.split("/").pop() || "");
}

function fileNameFromDisposition(value) {
  const utf8Match = value.match(/filename\*\s*=\s*UTF-8''([^;]+)/i);
  if (utf8Match) {
    return safeDecodeURIComponent(utf8Match[1].trim().replace(/^["']|["']$/g, ""));
  }

  const match = value.match(/filename\s*=\s*(?:"([^"]+)"|([^;]+))/i);
  if (!match) {
    return null;
  }
  return (match[1] || match[2] || "").trim().replace(/^["']|["']$/g, "");
}

function fileNameFromValue(value) {
  const trimmed = value.trim().replace(/^["']|["']$/g, "");
  if (!trimmed) {
    return null;
  }
  return trimmed.split(/[\\/]/).pop();
}

function hasDownloadableExtension(fileName) {
  const cleanName = fileName.split(/[?#]/)[0];
  const extension = cleanName.includes(".") ? cleanName.split(".").pop().toLowerCase() : "";
  return downloadableExtensions.has(extension);
}

function safeDecodeURIComponent(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}
