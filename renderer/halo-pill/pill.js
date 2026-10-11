// The "mic bubble" pill: shows what Halo is doing; click opens the panel.
const pill = document.getElementById("pill");
const label = document.getElementById("label");

const LABELS = {
  listening: "Listening…",
  thinking: "Thinking…",
  speaking: "Speaking…",
  waiting: "Needs your OK",
  followup: "Still listening…",
  idle: "Ready",
};

let voiceState = "idle";
let followUp = false;

function render() {
  const shown = voiceState === "idle" && followUp ? "followup" : voiceState;
  pill.dataset.state = shown;
  label.textContent = LABELS[shown] ?? "Ready";
  pill.classList.remove("out");
  // Tell main how big the window needs to be (capsule + shadow room).
  requestAnimationFrame(() => {
    // Capsule + the body padding around it (8 px sides, 6 top, 10 bottom for the shadow).
    const r = pill.getBoundingClientRect();
    window.halo.invoke("halo:pillResize", { width: Math.ceil(r.width) + 16, height: 48 }).catch(() => {});
  });
}

pill.addEventListener("click", () => window.halo.invoke("halo:openPanel"));

window.halo.on("halo:state", (s) => {
  voiceState = s;
  render();
});
window.halo.on("halo:wake", (w) => {
  followUp = w.mode === "followup";
  render();
});
// Main asks the pill to animate out before it hides the window.
window.halo.on("halo:pillOut", () => pill.classList.add("out"));

render();
