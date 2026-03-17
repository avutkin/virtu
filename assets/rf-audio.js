/* Resonance Finder — Web Audio tone generator
   Served from assets/ so the browser executes it on page load. */

window._rfAudioCtx = null;

window._rfPlayTone = function(freq, vol, dur) {
    try {
        if (!window._rfAudioCtx) {
            window._rfAudioCtx = new (window.AudioContext || window.webkitAudioContext)();
        }
        var ctx = window._rfAudioCtx;

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
            osc.stop(ctx.currentTime + dur);
        }

        /* AudioContext created outside a user-gesture callback starts suspended.
           resume() is async — wait for it before touching the timeline. */
        if (ctx.state === 'suspended') {
            ctx.resume().then(_play);
        } else {
            _play();
        }
    } catch(e) {
        console.warn('RF audio error:', e);
    }
};
