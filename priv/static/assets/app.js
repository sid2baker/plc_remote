(() => {
  if (
    "serviceWorker" in navigator &&
    window.isSecureContext &&
    window.location.hostname === "plc.setup"
  ) {
    navigator.serviceWorker.register("/service-worker.js").catch(() => {});
  }
})();
