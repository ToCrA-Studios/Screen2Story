#ifndef RUNNER_RECORDER_OVERLAY_H_
#define RUNNER_RECORDER_OVERLAY_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <gdiplus.h>
#include <sapi.h>
#pragma warning(push)
#pragma warning(disable : 4996)
#include <sphelper.h>
#pragma warning(pop)

#include <memory>
#include <string>

class RecorderOverlay {
 public:
  RecorderOverlay(flutter::BinaryMessenger* messenger, HWND owner);
  ~RecorderOverlay();

 private:
  enum class SelectionMode { kNone, kRegion, kWindow };
  using MethodResult = flutter::MethodResult<flutter::EncodableValue>;

  static LRESULT CALLBACK ToolbarProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  static LRESULT CALLBACK SelectionProc(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<MethodResult> result);
  void CreateToolbar();
  void ShowToolbar();
  void HideToolbar();
  void ShowConfirmation(const std::wstring& text);
  void BeginSelection(SelectionMode mode, const std::wstring& path,
                      std::unique_ptr<MethodResult> result);
  void CompleteSelection(POINT point);
  void CompleteSelection(RECT rect);
  void CancelSelection();

  bool CaptureDesktop(const std::wstring& path, std::wstring* error);
  bool CaptureRegion(const RECT& rect, const std::wstring& path,
                     std::wstring* error);
  bool CaptureWindow(HWND window, const std::wstring& path,
                     std::wstring* error);
  bool SaveBitmap(HBITMAP bitmap, const std::wstring& path,
                  std::wstring* error);
  std::wstring ChooseFolder();

  void ToggleVoice();
  void StartVoice();
  void StopVoice();
  void ProcessSpeechEvents();
  std::wstring FinishVoiceSegment();
  void SendVoiceState(const char* state);

  HWND owner_ = nullptr;
  HWND toolbar_ = nullptr;
  HWND confirmation_ = nullptr;
  HWND voice_button_ = nullptr;
  HWND selection_window_ = nullptr;
  POINT drag_start_{};
  POINT drag_current_{};
  bool dragging_ = false;
  SelectionMode selection_mode_ = SelectionMode::kNone;
  std::wstring selection_path_;
  std::unique_ptr<MethodResult> selection_result_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  ULONG_PTR gdiplus_token_ = 0;
  ISpRecognizer* recognizer_ = nullptr;
  ISpRecoContext* recognition_context_ = nullptr;
  ISpRecoGrammar* grammar_ = nullptr;
  std::wstring transcript_;
  bool voice_active_ = false;
};

#endif  // RUNNER_RECORDER_OVERLAY_H_
