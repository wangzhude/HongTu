import { FrameCallback } from '@kit.ArkUI';

/** A single after-render opportunity; the owner still validates page and modal authority. */
export class CanvasFocusReturnFrame extends FrameCallback {
  private finished: boolean = false;
  private action: () => void;

  constructor(action: () => void) {
    super();
    this.action = action;
  }

  onFrame(_frameTimeInNano: number): void {}

  onIdle(_timeLeftInNano: number): void {
    if (this.finished) return;
    this.finished = true;
    this.action();
  }
}
