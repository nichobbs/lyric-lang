/* Checks, against SDL's own headers, every event offset and flag constant that
 * lyric-window/src/window.l spells out.  Compiled (not run) by
 * scripts/ci/window-sdl-layout-check.sh: a mismatch is a compile error. */
#include <SDL3/SDL.h>
#include <stddef.h>

#define CHECK(name, cond) _Static_assert(cond, name)

CHECK("init video", SDL_INIT_VIDEO == 32);
CHECK("init audio", SDL_INIT_AUDIO == 16);
CHECK("init events", SDL_INIT_EVENTS == 16384);
CHECK("window resizable", SDL_WINDOW_RESIZABLE == 32);
CHECK("window hidden", SDL_WINDOW_HIDDEN == 8);
CHECK("window high pixel density", SDL_WINDOW_HIGH_PIXEL_DENSITY == 8192);
CHECK("default playback device", SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK == 0xFFFFFFFFu);

CHECK("quit", SDL_EVENT_QUIT == 256);
CHECK("window resized", SDL_EVENT_WINDOW_RESIZED == 518);
CHECK("window close requested", SDL_EVENT_WINDOW_CLOSE_REQUESTED == 528);
CHECK("key down", SDL_EVENT_KEY_DOWN == 768);
CHECK("key up", SDL_EVENT_KEY_UP == 769);
CHECK("text input", SDL_EVENT_TEXT_INPUT == 771);
CHECK("mouse motion", SDL_EVENT_MOUSE_MOTION == 1024);
CHECK("mouse button down", SDL_EVENT_MOUSE_BUTTON_DOWN == 1025);
CHECK("mouse button up", SDL_EVENT_MOUSE_BUTTON_UP == 1026);
CHECK("mouse wheel", SDL_EVENT_MOUSE_WHEEL == 1027);

CHECK("event buffer", sizeof(SDL_Event) == 128);
CHECK("common type", offsetof(SDL_CommonEvent, type) == 0);
CHECK("window id", offsetof(SDL_WindowEvent, windowID) == 16);
CHECK("window data1", offsetof(SDL_WindowEvent, data1) == 20);
CHECK("window data2", offsetof(SDL_WindowEvent, data2) == 24);
CHECK("key scancode", offsetof(SDL_KeyboardEvent, scancode) == 24);
CHECK("key key", offsetof(SDL_KeyboardEvent, key) == 28);
CHECK("key mod", offsetof(SDL_KeyboardEvent, mod) == 32);
CHECK("key down", offsetof(SDL_KeyboardEvent, down) == 36);
CHECK("key repeat", offsetof(SDL_KeyboardEvent, repeat) == 37);
CHECK("key window", offsetof(SDL_KeyboardEvent, windowID) == 16);
CHECK("text pointer", offsetof(SDL_TextInputEvent, text) == 24);
CHECK("editing text pointer", offsetof(SDL_TextEditingEvent, text) == 24);
CHECK("editing start", offsetof(SDL_TextEditingEvent, start) == 32);
CHECK("editing length", offsetof(SDL_TextEditingEvent, length) == 36);
CHECK("text editing event kind", SDL_EVENT_TEXT_EDITING == 770);
CHECK("motion x", offsetof(SDL_MouseMotionEvent, x) == 28);
CHECK("motion y", offsetof(SDL_MouseMotionEvent, y) == 32);
CHECK("motion dx", offsetof(SDL_MouseMotionEvent, xrel) == 36);
CHECK("motion dy", offsetof(SDL_MouseMotionEvent, yrel) == 40);
CHECK("button button", offsetof(SDL_MouseButtonEvent, button) == 24);
CHECK("button clicks", offsetof(SDL_MouseButtonEvent, clicks) == 26);
CHECK("button x", offsetof(SDL_MouseButtonEvent, x) == 28);
CHECK("button y", offsetof(SDL_MouseButtonEvent, y) == 32);
CHECK("wheel x", offsetof(SDL_MouseWheelEvent, x) == 24);
CHECK("wheel y", offsetof(SDL_MouseWheelEvent, y) == 28);

int main(void) { return 0; }
