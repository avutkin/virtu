/* Resonance Finder — Web Audio tone generator
   Loaded automatically by Dash from the assets/ folder. */
window._rfAudioCtx = null;
window._rfPlayTone = function(freq, vol, dur) {
    try {
        if (!window._rfAudioCtx) {
            window._rfAudioCtx = new AudioContext();
        }
        // Resume if suspended (browser autoplay policy)
        if (window._rfAudioCtx.state === 'suspended') {
            window._rfAudioCtx.resume();
        }
        var ctx  = window._rfAudioCtx;
        var osc  = ctx.createOscillator();
        var gain = ctx.createGain();
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.frequency.value = freq;
        osc.type = 'sine';
        gain.gain.setValueAtTime(0, ctx.currentTime);
        gain.gain.linearRampToValueAtTime(vol, ctx.currentTime + 0.15);
        gain.gain.linearRampToValueAtTime(0, ctx.currentTime + dur);
        osc.start(ctx.currentTime);
        osc.stop(ctx.currentTime + dur);
    } catch(e) {
        console.warn('RF audio error:', e);
    }
};
