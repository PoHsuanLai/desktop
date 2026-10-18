import React from "react";
import { createRoot } from "react-dom/client";
import { Excalidraw } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";

// Fonts and other assets come from this server, never a CDN: the run is offline.
window.EXCALIDRAW_ASSET_PATH = "/";

function App() {
  return (
    <div style={{ position: "fixed", inset: 0 }}>
      <Excalidraw name="lamp" />
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
