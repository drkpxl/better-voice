// Ambient types for the native <-> web bridge contract. See main.ts for the full
// explanation; kept separate so main.ts stays focused on behavior.
export {};

declare global {
  interface EditorAPI {
    setText(text: string): void;
    getText(): string;
    setReadOnly(readOnly: boolean): void;
    __debugInsertText(text: string): void;
  }

  interface Window {
    editorAPI?: EditorAPI;
    webkit?: {
      messageHandlers?: {
        bridge?: {
          postMessage(message: unknown): void;
        };
      };
    };
  }
}
