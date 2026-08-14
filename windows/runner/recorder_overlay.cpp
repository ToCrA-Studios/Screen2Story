#include "recorder_overlay.h"

#include <flutter/encodable_value.h>
#include <shobjidl.h>

#include <algorithm>

namespace {
constexpr wchar_t kToolbarClass[] = L"S2S_RECORDER_TOOLBAR";
constexpr wchar_t kSelectionClass[] = L"S2S_CAPTURE_SELECTION";
constexpr UINT kSpeechMessage = WM_APP + 31;
constexpr int kPhotoButton = 1001;
constexpr int kRegionButton = 1002;
constexpr int kWindowButton = 1003;
constexpr int kVoiceButton = 1004;

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                       0, nullptr, nullptr);
  std::string output(std::max(size - 1, 0), '\0');
  if (size > 1) {
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, output.data(), size - 1,
                        nullptr, nullptr);
  }
  return output;
}

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  std::wstring output(std::max(size - 1, 0), L'\0');
  if (size > 1) {
    MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, output.data(), size - 1);
  }
  return output;
}

int PngEncoderClsid(CLSID* clsid) {
  UINT count = 0;
  UINT size = 0;
  Gdiplus::GetImageEncodersSize(&count, &size);
  if (size == 0) return -1;
  auto data = std::make_unique<BYTE[]>(size);
  auto codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(data.get());
  if (Gdiplus::GetImageEncoders(count, size, codecs) != Gdiplus::Ok) return -1;
  for (UINT index = 0; index < count; ++index) {
    if (wcscmp(codecs[index].MimeType, L"image/png") == 0) {
      *clsid = codecs[index].Clsid;
      return static_cast<int>(index);
    }
  }
  return -1;
}

}  // namespace

RecorderOverlay::RecorderOverlay(flutter::BinaryMessenger* messenger, HWND owner)
    : owner_(owner) {
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr);
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "screenshot_story_recorder/overlay",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

RecorderOverlay::~RecorderOverlay() {
  StopVoice();
  if (selection_window_) DestroyWindow(selection_window_);
  if (toolbar_) DestroyWindow(toolbar_);
  if (gdiplus_token_) Gdiplus::GdiplusShutdown(gdiplus_token_);
}

void RecorderOverlay::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<MethodResult> result) {
  const std::string& method = call.method_name();
  if (method == "showToolbar") {
    ShowToolbar();
    result->Success();
  } else if (method == "hideToolbar") {
    HideToolbar();
    result->Success();
  } else if (method == "captureConfirmation") {
    const auto* value = std::get_if<std::string>(call.arguments());
    ShowConfirmation(value ? Wide(*value) : L"");
    result->Success();
  } else if (method == "chooseFolder") {
    const std::wstring folder = ChooseFolder();
    if (folder.empty()) {
      result->Success();
    } else {
      result->Success(flutter::EncodableValue(Utf8(folder)));
    }
  } else if (method == "voiceBoundary") {
    result->Success(flutter::EncodableValue(Utf8(FinishVoiceSegment())));
  } else if (method == "captureScreen" || method == "captureRegion" ||
             method == "captureWindow") {
    const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    const auto path_key = flutter::EncodableValue("path");
    if (!arguments || arguments->find(path_key) == arguments->end()) {
      result->Error("INVALID_PATH", "Kein Bildpfad");
      return;
    }
    const auto* path = std::get_if<std::string>(&arguments->at(path_key));
    if (!path) {
      result->Error("INVALID_PATH", "Kein Bildpfad");
      return;
    }
    if (method == "captureScreen") {
      std::wstring error;
      if (CaptureDesktop(Wide(*path), &error)) {
        result->Success();
      } else {
        result->Error("CAPTURE_FAILED", Utf8(error));
      }
    } else {
      BeginSelection(method == "captureRegion" ? SelectionMode::kRegion
                                                : SelectionMode::kWindow,
                     Wide(*path), std::move(result));
    }
  } else {
    result->NotImplemented();
  }
}

void RecorderOverlay::CreateToolbar() {
  if (toolbar_) return;
  WNDCLASS window_class{};
  window_class.lpfnWndProc = ToolbarProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.hbrBackground = CreateSolidBrush(RGB(30, 30, 30));
  window_class.lpszClassName = kToolbarClass;
  RegisterClass(&window_class);
  toolbar_ = CreateWindowEx(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                            kToolbarClass, L"S2S", WS_POPUP, 0, 0, 520, 48,
                            owner_, nullptr, GetModuleHandle(nullptr), this);
  const DWORD button_style = WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON;
  CreateWindow(L"BUTTON", L"Foto", button_style, 8, 8, 78, 32, toolbar_,
               reinterpret_cast<HMENU>(static_cast<INT_PTR>(kPhotoButton)),
               nullptr, nullptr);
  CreateWindow(L"BUTTON", L"Auswahl", button_style, 92, 8, 86, 32, toolbar_,
               reinterpret_cast<HMENU>(static_cast<INT_PTR>(kRegionButton)),
               nullptr, nullptr);
  CreateWindow(L"BUTTON", L"Fenster", button_style, 184, 8, 82, 32, toolbar_,
               reinterpret_cast<HMENU>(static_cast<INT_PTR>(kWindowButton)),
               nullptr, nullptr);
  voice_button_ = CreateWindow(
      L"BUTTON", L"Voice", button_style, 272, 8, 78, 32, toolbar_,
      reinterpret_cast<HMENU>(static_cast<INT_PTR>(kVoiceButton)), nullptr,
      nullptr);
  confirmation_ = CreateWindow(L"STATIC", L"", WS_CHILD | SS_CENTERIMAGE,
                               360, 8, 152, 32, toolbar_, nullptr, nullptr,
                               nullptr);
  SetWindowLongPtr(confirmation_, GWL_STYLE,
                   GetWindowLongPtr(confirmation_, GWL_STYLE) & ~WS_VISIBLE);
}

void RecorderOverlay::ShowToolbar() {
  CreateToolbar();
  if (!IsWindowVisible(toolbar_)) {
    RECT work{};
    SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
    RECT current{};
    GetWindowRect(toolbar_, &current);
    if (current.left == 0 && current.top == 0) {
      SetWindowPos(toolbar_, HWND_TOPMOST, work.right - 544, work.top + 24, 520,
                   48, SWP_NOACTIVATE);
    }
  }
  ShowWindow(toolbar_, SW_SHOWNOACTIVATE);
  SetWindowPos(toolbar_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void RecorderOverlay::HideToolbar() {
  if (toolbar_) ShowWindow(toolbar_, SW_HIDE);
}

void RecorderOverlay::ShowConfirmation(const std::wstring& text) {
  CreateToolbar();
  SetWindowText(confirmation_, text.c_str());
  ShowWindow(confirmation_, SW_SHOWNA);
  SetTimer(toolbar_, 1, 2000, nullptr);
}

LRESULT CALLBACK RecorderOverlay::ToolbarProc(HWND hwnd, UINT message,
                                               WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<RecorderOverlay*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    self = static_cast<RecorderOverlay*>(create->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(hwnd, message, wparam, lparam);
  if (message == WM_COMMAND) {
    const int command = LOWORD(wparam);
    if (command == kPhotoButton) {
      self->channel_->InvokeMethod(
          "capture", std::make_unique<flutter::EncodableValue>(
                         std::string("screen")));
    } else if (command == kRegionButton) {
      self->channel_->InvokeMethod(
          "capture", std::make_unique<flutter::EncodableValue>(
                         std::string("region")));
    } else if (command == kWindowButton) {
      self->channel_->InvokeMethod(
          "capture", std::make_unique<flutter::EncodableValue>(
                         std::string("window")));
    } else if (command == kVoiceButton) {
      self->ToggleVoice();
    }
    return 0;
  }
  if (message == WM_NCHITTEST) {
    const LRESULT hit = DefWindowProc(hwnd, message, wparam, lparam);
    return hit == HTCLIENT ? HTCAPTION : hit;
  }
  if (message == WM_TIMER) {
    ShowWindow(self->confirmation_, SW_HIDE);
    KillTimer(hwnd, 1);
    return 0;
  }
  if (message == kSpeechMessage) {
    self->ProcessSpeechEvents();
    return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

void RecorderOverlay::BeginSelection(SelectionMode mode,
                                     const std::wstring& path,
                                     std::unique_ptr<MethodResult> result) {
  selection_mode_ = mode;
  selection_path_ = path;
  selection_result_ = std::move(result);
  WNDCLASS window_class{};
  window_class.lpfnWndProc = SelectionProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.hCursor = LoadCursor(nullptr, IDC_CROSS);
  window_class.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(NULL_BRUSH));
  window_class.lpszClassName = kSelectionClass;
  RegisterClass(&window_class);
  const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  selection_window_ = CreateWindowEx(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED, kSelectionClass, L"",
      WS_POPUP, left, top, width, height, nullptr, nullptr,
      GetModuleHandle(nullptr), this);
  SetLayeredWindowAttributes(selection_window_, RGB(0, 0, 0), 32, LWA_ALPHA);
  ShowWindow(selection_window_, SW_SHOW);
  SetForegroundWindow(selection_window_);
  SetCapture(selection_window_);
}

LRESULT CALLBACK RecorderOverlay::SelectionProc(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<RecorderOverlay*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    self = static_cast<RecorderOverlay*>(create->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(hwnd, message, wparam, lparam);
  if (message == WM_LBUTTONDOWN) {
    self->dragging_ = true;
    GetCursorPos(&self->drag_start_);
    self->drag_current_ = self->drag_start_;
    return 0;
  }
  if (message == WM_MOUSEMOVE && self->dragging_) {
    GetCursorPos(&self->drag_current_);
    InvalidateRect(hwnd, nullptr, TRUE);
    return 0;
  }
  if (message == WM_LBUTTONUP) {
    POINT point{};
    GetCursorPos(&point);
    self->dragging_ = false;
    if (self->selection_mode_ == SelectionMode::kWindow) {
      self->CompleteSelection(point);
    } else {
      RECT rect{std::min(self->drag_start_.x, point.x),
                std::min(self->drag_start_.y, point.y),
                std::max(self->drag_start_.x, point.x),
                std::max(self->drag_start_.y, point.y)};
      self->CompleteSelection(rect);
    }
    return 0;
  }
  if (message == WM_KEYDOWN && wparam == VK_ESCAPE) {
    self->CancelSelection();
    return 0;
  }
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(hwnd, &paint);
    if (self->dragging_ && self->selection_mode_ == SelectionMode::kRegion) {
      POINT start = self->drag_start_;
      POINT current = self->drag_current_;
      ScreenToClient(hwnd, &start);
      ScreenToClient(hwnd, &current);
      HPEN pen = CreatePen(PS_SOLID, 2, RGB(255, 255, 255));
      HGDIOBJ old_pen = SelectObject(dc, pen);
      HGDIOBJ old_brush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
      Rectangle(dc, start.x, start.y, current.x, current.y);
      SelectObject(dc, old_brush);
      SelectObject(dc, old_pen);
      DeleteObject(pen);
    }
    EndPaint(hwnd, &paint);
    return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

void RecorderOverlay::CompleteSelection(POINT point) {
  ReleaseCapture();
  ShowWindow(selection_window_, SW_HIDE);
  HWND selected = WindowFromPoint(point);
  selected = selected ? GetAncestor(selected, GA_ROOT) : nullptr;
  std::wstring error;
  const bool success = selected && selected != owner_ && selected != toolbar_ &&
                       CaptureWindow(selected, selection_path_, &error);
  DestroyWindow(selection_window_);
  selection_window_ = nullptr;
  selection_mode_ = SelectionMode::kNone;
  if (success) {
    selection_result_->Success();
  } else {
    selection_result_->Error(
        "CAPTURE_FAILED",
        Utf8(error.empty() ? L"Kein Fenster gefunden" : error));
  }
  selection_result_.reset();
}

void RecorderOverlay::CompleteSelection(RECT rect) {
  ReleaseCapture();
  ShowWindow(selection_window_, SW_HIDE);
  std::wstring error;
  const bool valid = rect.right - rect.left > 4 && rect.bottom - rect.top > 4;
  const bool success = valid && CaptureRegion(rect, selection_path_, &error);
  DestroyWindow(selection_window_);
  selection_window_ = nullptr;
  selection_mode_ = SelectionMode::kNone;
  if (success) {
    selection_result_->Success();
  } else {
    selection_result_->Error(
        "CAPTURE_FAILED",
        Utf8(error.empty() ? L"Auswahl ist zu klein" : error));
  }
  selection_result_.reset();
}

void RecorderOverlay::CancelSelection() {
  ReleaseCapture();
  DestroyWindow(selection_window_);
  selection_window_ = nullptr;
  selection_mode_ = SelectionMode::kNone;
  selection_result_->Error("CAPTURE_CANCELLED", "Aufnahme abgebrochen");
  selection_result_.reset();
}

bool RecorderOverlay::CaptureDesktop(const std::wstring& path,
                                     std::wstring* error) {
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  const HMONITOR monitor = MonitorFromWindow(owner_, MONITOR_DEFAULTTOPRIMARY);
  if (!GetMonitorInfo(monitor, &monitor_info)) {
    *error = L"Bildschirmgröße konnte nicht gelesen werden";
    return false;
  }
  return CaptureRegion(monitor_info.rcMonitor, path, error);
}

bool RecorderOverlay::CaptureRegion(const RECT& rect, const std::wstring& path,
                                    std::wstring* error) {
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  HDC screen = GetDC(nullptr);
  HDC memory = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
  HGDIOBJ previous = SelectObject(memory, bitmap);
  const BOOL copied = BitBlt(memory, 0, 0, width, height, screen, rect.left,
                             rect.top, SRCCOPY | CAPTUREBLT);
  SelectObject(memory, previous);
  DeleteDC(memory);
  ReleaseDC(nullptr, screen);
  if (!copied) {
    DeleteObject(bitmap);
    *error = L"Bildschirm konnte nicht aufgenommen werden";
    return false;
  }
  const bool saved = SaveBitmap(bitmap, path, error);
  DeleteObject(bitmap);
  return saved;
}

bool RecorderOverlay::CaptureWindow(HWND window, const std::wstring& path,
                                    std::wstring* error) {
  RECT rect{};
  if (!GetWindowRect(window, &rect)) {
    *error = L"Fenstergröße konnte nicht gelesen werden";
    return false;
  }
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  HDC screen = GetDC(nullptr);
  HDC memory = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
  HGDIOBJ previous = SelectObject(memory, bitmap);
  BOOL copied = PrintWindow(window, memory, 2);
  if (!copied) {
    copied = BitBlt(memory, 0, 0, width, height, screen, rect.left, rect.top,
                    SRCCOPY | CAPTUREBLT);
  }
  SelectObject(memory, previous);
  DeleteDC(memory);
  ReleaseDC(nullptr, screen);
  if (!copied) {
    DeleteObject(bitmap);
    *error = L"Fenster konnte nicht aufgenommen werden";
    return false;
  }
  const bool saved = SaveBitmap(bitmap, path, error);
  DeleteObject(bitmap);
  return saved;
}

bool RecorderOverlay::SaveBitmap(HBITMAP bitmap, const std::wstring& path,
                                 std::wstring* error) {
  CLSID encoder{};
  if (PngEncoderClsid(&encoder) < 0) {
    *error = L"PNG-Encoder ist nicht verfügbar";
    return false;
  }
  Gdiplus::Bitmap image(bitmap, nullptr);
  if (image.Save(path.c_str(), &encoder, nullptr) != Gdiplus::Ok) {
    *error = L"PNG-Datei konnte nicht gespeichert werden";
    return false;
  }
  return true;
}

std::wstring RecorderOverlay::ChooseFolder() {
  IFileDialog* dialog = nullptr;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
    return {};
  }
  DWORD options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
  dialog->SetTitle(L"Speicherort wählen");
  std::wstring path;
  if (SUCCEEDED(dialog->Show(owner_))) {
    IShellItem* item = nullptr;
    if (SUCCEEDED(dialog->GetResult(&item))) {
      PWSTR value = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &value))) {
        path = value;
        CoTaskMemFree(value);
      }
      item->Release();
    }
  }
  dialog->Release();
  return path;
}

void RecorderOverlay::ToggleVoice() {
  if (voice_active_) StopVoice(); else StartVoice();
}

void RecorderOverlay::StartVoice() {
  if (!toolbar_) CreateToolbar();
  HRESULT result = CoCreateInstance(CLSID_SpSharedRecognizer, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&recognizer_));
  if (SUCCEEDED(result)) result = recognizer_->CreateRecoContext(&recognition_context_);
  if (SUCCEEDED(result)) {
    result = recognition_context_->SetNotifyWindowMessage(toolbar_, kSpeechMessage, 0, 0);
  }
  if (SUCCEEDED(result)) {
    const ULONGLONG events = SPFEI(SPEI_RECOGNITION) |
                             SPFEI(SPEI_FALSE_RECOGNITION);
    result = recognition_context_->SetInterest(events, events);
  }
  if (SUCCEEDED(result)) result = recognition_context_->CreateGrammar(1, &grammar_);
  if (SUCCEEDED(result)) result = grammar_->LoadDictation(nullptr, SPLO_STATIC);
  if (SUCCEEDED(result)) result = grammar_->SetDictationState(SPRS_ACTIVE);
  if (FAILED(result)) {
    StopVoice();
    SendVoiceState("localUnavailable");
    return;
  }
  transcript_.clear();
  voice_active_ = true;
  SetWindowText(voice_button_, L"Stop");
  SendVoiceState("recording");
}

void RecorderOverlay::StopVoice() {
  const bool was_active = voice_active_;
  const std::wstring text = FinishVoiceSegment();
  voice_active_ = false;
  if (grammar_) {
    grammar_->SetDictationState(SPRS_INACTIVE);
    grammar_->Release();
    grammar_ = nullptr;
  }
  if (recognition_context_) {
    recognition_context_->Release();
    recognition_context_ = nullptr;
  }
  if (recognizer_) {
    recognizer_->Release();
    recognizer_ = nullptr;
  }
  if (voice_button_) SetWindowText(voice_button_, L"Voice");
  if (was_active && !text.empty()) {
    channel_->InvokeMethod("voiceText",
                           std::make_unique<flutter::EncodableValue>(Utf8(text)));
  }
  if (was_active) SendVoiceState("idle");
}

void RecorderOverlay::ProcessSpeechEvents() {
  if (!recognition_context_) return;
  CSpEvent event;
  while (event.GetFrom(recognition_context_) == S_OK) {
    if (event.eEventId == SPEI_RECOGNITION && event.RecoResult()) {
      WCHAR* text = nullptr;
      if (SUCCEEDED(event.RecoResult()->GetText(
              static_cast<ULONG>(SP_GETWHOLEPHRASE),
              static_cast<ULONG>(SP_GETWHOLEPHRASE), TRUE,
                                                &text, nullptr)) && text) {
        if (!transcript_.empty()) transcript_ += L" ";
        transcript_ += text;
        CoTaskMemFree(text);
      }
    }
  }
}

std::wstring RecorderOverlay::FinishVoiceSegment() {
  std::wstring value = transcript_;
  transcript_.clear();
  return value;
}

void RecorderOverlay::SendVoiceState(const char* state) {
  channel_->InvokeMethod(
      "voiceState",
      std::make_unique<flutter::EncodableValue>(std::string(state)));
}
