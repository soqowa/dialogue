class Segmenter extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.target = 16000; this.sum = 0; this.count = 0; this.phase = 0;
    this.frame = []; this.pre = []; this.segment = []; this.active = false;
    this.silence = 0; this.voiced = 0; this.sent = 0; this.seq = 0;
    this.threshold = options.processorOptions?.threshold || 0.009;
    this.pause = options.processorOptions?.pause || 480;
    this.port.onmessage = ({ data }) => { if (data === 'flush') this.finish(); };
  }
  publish(final) {
    if (this.segment.length < 4000 || this.voiced < 1600) return;
    const pcm = new Int16Array(this.segment.length);
    for (let i = 0; i < pcm.length; i++) pcm[i] = Math.round(Math.max(-1, Math.min(1, this.segment[i])) * 32767);
    this.port.postMessage({ type: 'audio', audio: pcm.buffer, final, seq: this.seq }, [pcm.buffer]);
    this.sent = this.segment.length;
  }
  finish() {
    if (this.active) this.publish(true);
    this.active = false; this.segment = []; this.voiced = 0; this.silence = 0; this.sent = 0;
  }
  consume(frame) {
    const rms = Math.sqrt(frame.reduce((s, v) => s + v * v, 0) / frame.length);
    this.port.postMessage({ type: 'level', level: rms });
    if (!this.active) {
      this.pre.push(...frame); if (this.pre.length > 3200) this.pre.splice(0, this.pre.length - 3200);
      if (rms < this.threshold) return;
      this.active = true; this.seq++; this.segment = this.pre.splice(0); this.sent = 0;
    } else this.segment.push(...frame);
    if (rms >= this.threshold) { this.voiced += frame.length; this.silence = 0; }
    else this.silence += frame.length;
    if (this.silence >= this.pause * 16 || this.segment.length >= 16 * 14000) this.finish();
    else if (this.segment.length - this.sent >= 16 * 1500) this.publish(false);
  }
  process(inputs) {
    const channels = inputs[0]; if (!channels?.[0]) return true;
    for (let i = 0; i < channels[0].length; i++) {
      let value = 0; for (let c = 0; c < channels.length; c++) value += channels[c][i]; value /= channels.length;
      this.sum += value; this.count++; this.phase += this.target;
      if (this.phase >= sampleRate) {
        this.phase -= sampleRate; this.frame.push(this.sum / this.count); this.sum = 0; this.count = 0;
        if (this.frame.length === 320) { this.consume(this.frame); this.frame = []; }
      }
    }
    return true;
  }
}
registerProcessor('segmenter', Segmenter);
