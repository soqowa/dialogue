export class CallAudio {
  constructor(onAudio, onLevel, onEnded) { this.onAudio = onAudio; this.onLevel = onLevel; this.onEnded = onEnded; this.streams = []; this.nodes = []; this.times = new Map(); }
  async start({ microphone, language, pause, threshold }) {
    this.language = language;
    try {
      // Keep the display track alive: stopping it can also stop shared-tab audio.
      const display = await navigator.mediaDevices.getDisplayMedia({ video: { displaySurface: 'browser', frameRate: 1, width: 1, height: 1 }, audio: true, preferCurrentTab: false, selfBrowserSurface: 'exclude', systemAudio: 'include' });
      this.streams.push(display);
      const track = display.getAudioTracks()[0];
      if (!track || track.readyState === 'ended') throw new Error('Звук вкладки не передан. В Chrome выберите вкладку Google Meet и включите «Также предоставить доступ к аудио вкладки».');
      track.addEventListener('ended', () => this.onEnded());
      display.getVideoTracks().forEach(t => t.addEventListener('ended', () => this.onEnded()));
      if (microphone) {
        const mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }, video: false });
        this.streams.push(mic);
        mic.getAudioTracks()[0].addEventListener('ended', () => this.onEnded());
      }
      this.context = new AudioContext({ sampleRate: 16000 });
      await this.context.audioWorklet.addModule('/pcm-worklet.js'); await this.context.resume();
      this.prefix = crypto.randomUUID();
      this.streams.forEach((stream, index) => {
        const source = index === 0 ? 'remote' : 'mic';
        const input = this.context.createMediaStreamSource(new MediaStream(stream.getAudioTracks()));
        const processor = new AudioWorkletNode(this.context, 'segmenter', { processorOptions: { pause, threshold } });
        const gain = this.context.createGain(); gain.gain.value = 0;
        input.connect(processor); processor.connect(gain); gain.connect(this.context.destination);
        processor.port.onmessage = ({ data }) => {
          if (data.type === 'level') { this.onLevel(source, data.level); return; }
          const id = `${this.prefix}-${source}-${data.seq}`;
          if (!this.times.has(id)) this.times.set(id, Date.now() - data.audio.byteLength / 32);
          const bytes = new Uint8Array(data.audio); let binary = '';
          for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
          this.onAudio({ type: 'audio', source, id, audio: btoa(binary), final: data.final, time: this.times.get(id), language });
          if (data.final) this.times.delete(id);
        };
        this.nodes.push({ input, processor, gain });
      });
    } catch (error) { await this.stop(); throw error; }
  }
  async stop() {
    for (const { processor } of this.nodes) processor.port.postMessage('flush');
    await new Promise(resolve => setTimeout(resolve, 80));
    for (const stream of this.streams) for (const track of stream.getTracks()) track.stop();
    for (const { input, processor, gain } of this.nodes) { input.disconnect(); processor.disconnect(); gain.disconnect(); }
    if (this.context && this.context.state !== 'closed') await this.context.close();
    this.streams = []; this.nodes = [];
  }
}
