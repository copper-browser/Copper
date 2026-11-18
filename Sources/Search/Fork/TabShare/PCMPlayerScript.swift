import Foundation

// The page's half of sound Copper hands a page (TabShareAudio, PageMic): a
// long poll for pieces of 16-bit PCM, each played into a Web Audio graph
// whose MediaStreamAudioDestinationNode is the page's audio track.
//
// One AudioBufferSourceNode per piece, each started where the last one ends,
// a twentieth of a second ahead of the context's clock. No AudioWorklet: a
// worklet's module has to load from a URL the page's Content Security
// Policy allows, and many pages (calls among them) allow none Copper could
// use. The latency stays bounded: a piece that would start more than a
// quarter of a second ahead is dropped (the page fell behind, or Copper's
// clock runs faster than the page's), a piece that would start late starts
// the lead again, and nothing is scheduled while the context is not
// running — so sound never piles up behind a suspended context.
enum PCMPlayerScript {
    /// Seconds ahead of the context's clock a piece starts after a gap.
    static let lead = 0.05
    /// The furthest ahead a piece may be scheduled before it is dropped.
    static let most = 0.25

    /// `copperPlayer(context, destination, pull, ended, decode)`: `pull(after)`
    /// answers a promise of a piece (`{seq, frames, rate, channels, data}`),
    /// `{seq: 0}` (ask again) or `{ended, reason}`; `ended(reason)` is called
    /// once when the source is over; `decode(base64)` gives the bytes. It
    /// returns `{ stop(), state }`. A JS function expression, for a script to
    /// bind under a name of its own.
    static let source = """
    (context, destination, pull, ended, decode) => {
      const lead = \(lead), most = \(most);
      const state = { live: true, seq: 0, next: 0, played: 0, dropped: 0 };
      const play = (piece) => {
        const frames = piece.frames | 0, channels = piece.channels | 0, rate = +piece.rate;
        if (!(frames > 0 && channels > 0 && channels <= 2 && rate >= 8000 && rate <= 192000)) return;
        if (context.state !== 'running') { state.next = 0; state.dropped += frames; return; }
        const bytes = decode(piece.data);
        if (!bytes || bytes.length < frames * channels * 2) return;
        const now = context.currentTime;
        if (state.next < now + 0.005) state.next = now + lead;
        else if (state.next > now + most) { state.dropped += frames; return; }
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        const buffer = context.createBuffer(channels, frames, rate);
        for (let c = 0; c < channels; c++) {
          const out = buffer.getChannelData(c);
          for (let i = 0; i < frames; i++) out[i] = view.getInt16((i * channels + c) * 2, true) / 32768;
        }
        const node = context.createBufferSource();
        node.buffer = buffer;
        node.connect(destination);
        node.start(state.next);
        state.next += frames / rate;
        state.played += frames;
      };
      (async () => {
        while (state.live) {
          let piece;
          try { piece = await pull(state.seq); } catch (e) { piece = { ended: true, reason: 'error' }; }
          if (!state.live) return;
          if (!piece || piece.ended) { state.live = false; ended(piece ? piece.reason : 'gone'); return; }
          if (typeof piece.seq !== 'number' || piece.seq <= state.seq) continue;
          state.seq = piece.seq;
          try { play(piece); } catch (e) { /* one bad piece: the next one */ }
        }
      })();
      return { state, stop() { state.live = false; } };
    }
    """
}
