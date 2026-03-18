/* Resonance Finder — Web Audio
   Served from assets/ so the browser executes it on page load.

   Two interfaces:
     _rfPlayTone(freq, vol, dur)   — one-shot chime (kept for future use)
     _rfPacerBreath(tFreq, tVol)  — continuously updates a persistent sweep
                                    oscillator (created lazily on first call)
     _rfPacerStop()               — graceful 500 ms fade-out + cleanup
*/

window._rfAudioCtx  = null;
window._rfPacerOsc  = null;
window._rfPacerGain = null;

function _rfCtx() {
    if (!window._rfAudioCtx) {
        window._rfAudioCtx = new (window.AudioContext || window.webkitAudioContext)();
    }
    return window._rfAudioCtx;
}

/* One-shot tone ─────────────────────────────────────────────────────────── */
window._rfPlayTone = function(freq, vol, dur) {
    try {
        var ctx = _rfCtx();
        function _play() {
            var osc  = ctx.createOscillator();
            var gain = ctx.createGain();
            osc.connect(gain);
            gain.connect(ctx.destination);
            osc.frequency.value = freq;
            osc.type = 'sine';
            gain.gain.setValueAtTime(0, ctx.currentTime);
            gain.gain.linearRampToValueAtTime(vol, ctx.currentTime + 0.15);
            gain.gain.linearRampToValueAtTime(0,   ctx.currentTime + dur);
            osc.start(ctx.currentTime);
            osc.stop(ctx.currentTime  + dur);
        }
        if (ctx.state === 'suspended') { ctx.resume().then(_play); }
        else { _play(); }
    } catch(e) { console.warn('RF tone error:', e); }
};

/* Continuous breathing sweep ────────────────────────────────────────────────
   Called every ~100 ms from the pacer animation tick.
   The oscillator is created once and kept alive; its frequency and gain are
   ramped smoothly to (tFreq, tVol) over 120 ms so the sound is perfectly
   continuous — no clicks, no gaps.
   Frequency rises during inhale (low → high) and falls during exhale
   (high → low), mirroring the physical sensation of filling and releasing.   */
window._rfPacerBreath = function(tFreq, tVol) {
    try {
        var ctx = _rfCtx();
        function _update() {
            if (!window._rfPacerOsc) {
                /* First call — create oscillator chain */
                var osc  = ctx.createOscillator();
                var gain = ctx.createGain();
                /* Light compression prevents harsh clipping at peak */
                var comp = ctx.createDynamicsCompressor();
                comp.threshold.value = -18;
                comp.ratio.value     =   4;
                comp.attack.value    = 0.005;
                comp.release.value   = 0.10;
                osc.type            = 'sine';
                osc.frequency.value = tFreq;
                gain.gain.value     = 0;
                osc.connect(gain);
                gain.connect(comp);
                comp.connect(ctx.destination);
                osc.start();
                window._rfPacerOsc  = osc;
                window._rfPacerGain = gain;
            }
            var t    = ctx.currentTime;
            var osc  = window._rfPacerOsc;
            var gain = window._rfPacerGain;
            /* Cancel any pending ramps, anchor current value, ramp to target */
            osc.frequency.cancelScheduledValues(t);
            osc.frequency.setValueAtTime(osc.frequency.value, t);
            osc.frequency.linearRampToValueAtTime(tFreq, t + 0.12);
            gain.gain.cancelScheduledValues(t);
            gain.gain.setValueAtTime(gain.gain.value, t);
            gain.gain.linearRampToValueAtTime(tVol,  t + 0.12);
        }
        if (ctx.state === 'suspended') { ctx.resume().then(_update); }
        else { _update(); }
    } catch(e) { console.warn('RF pacer breath error:', e); }
};

/* Graceful stop — 500 ms fade then oscillator destroyed ─────────────────── */
window._rfPacerStop = function() {
    try {
        if (!window._rfPacerOsc) return;
        var ctx  = window._rfAudioCtx;
        var gain = window._rfPacerGain;
        var t    = ctx.currentTime;
        gain.gain.cancelScheduledValues(t);
        gain.gain.setValueAtTime(gain.gain.value, t);
        gain.gain.linearRampToValueAtTime(0, t + 0.5);
        var osc = window._rfPacerOsc;
        window._rfPacerOsc  = null;
        window._rfPacerGain = null;
        setTimeout(function() { try { osc.stop(); } catch(e) {} }, 700);
    } catch(e) {
        window._rfPacerOsc  = null;
        window._rfPacerGain = null;
    }
};
