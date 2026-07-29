#include "flutter_window.h"

#include <cwchar>
#include <mmsystem.h>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       value.c_str(), -1, nullptr, 0);
  if (size == 0) {
    return std::wstring();
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1,
                      result.data(), size);
  result.pop_back();
  return result;
}

const std::string* StringArgument(const flutter::EncodableValue* arguments,
                                  const char* key) {
  if (arguments == nullptr) {
    return nullptr;
  }
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return nullptr;
  }
  const auto found = map->find(flutter::EncodableValue(key));
  if (found == map->end()) {
    return nullptr;
  }
  return std::get_if<std::string>(&found->second);
}

void SelectVoiceForLanguage(ISpVoice* voice, const wchar_t* language) {
  ISpObjectTokenCategory* category = nullptr;
  if (FAILED(CoCreateInstance(CLSID_SpObjectTokenCategory, nullptr, CLSCTX_ALL,
                              IID_ISpObjectTokenCategory,
                              reinterpret_cast<void**>(&category)))) {
    return;
  }
  if (FAILED(category->SetId(SPCAT_VOICES, FALSE))) {
    category->Release();
    return;
  }
  IEnumSpObjectTokens* tokens = nullptr;
  if (FAILED(category->EnumTokens(nullptr, nullptr, &tokens))) {
    category->Release();
    return;
  }
  ISpObjectToken* token = nullptr;
  ULONG fetched = 0;
  while (tokens->Next(1, &token, &fetched) == S_OK) {
    wchar_t* token_language = nullptr;
    if (SUCCEEDED(token->GetStringValue(L"Language", &token_language))) {
      const bool matches = wcsstr(token_language, language) != nullptr;
      CoTaskMemFree(token_language);
      if (matches) {
        voice->SetVoice(token);
        token->Release();
        break;
      }
    }
    token->Release();
    token = nullptr;
  }
  tokens->Release();
  category->Release();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL, IID_ISpVoice,
                   reinterpret_cast<void**>(&speech_voice_));
  speech_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "io.github.chingfuhan.myduo/speech",
          &flutter::StandardMethodCodec::GetInstance());
  speech_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "speak") {
          const std::string* text =
              StringArgument(call.arguments(), "text");
          const std::string* locale =
              StringArgument(call.arguments(), "locale");
          if (speech_voice_ == nullptr || text == nullptr || text->empty()) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const wchar_t* language =
              locale != nullptr && *locale == "en-GB" ? L"Language=809"
                                                       : L"Language=409";
          SelectVoiceForLanguage(speech_voice_, language);
          speech_voice_->SetRate(-1);
          const std::wstring wide_text = WideFromUtf8(*text);
          const HRESULT status = speech_voice_->Speak(
              wide_text.c_str(), SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
          result->Success(flutter::EncodableValue(SUCCEEDED(status)));
          return;
        }
        if (call.method_name() == "playAudio") {
          const std::string* path =
              StringArgument(call.arguments(), "path");
          if (path == nullptr || path->empty()) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const std::wstring wide_path = WideFromUtf8(*path);
          const bool played =
              PlaySoundW(wide_path.c_str(), nullptr,
                         SND_FILENAME | SND_ASYNC | SND_NODEFAULT) != FALSE;
          result->Success(flutter::EncodableValue(played));
          return;
        }
        if (call.method_name() == "stop") {
          PlaySoundW(nullptr, nullptr, 0);
          if (speech_voice_ != nullptr) {
            speech_voice_->Speak(L"", SPF_ASYNC | SPF_PURGEBEFORESPEAK,
                                 nullptr);
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  speech_channel_.reset();
  if (speech_voice_ != nullptr) {
    speech_voice_->Release();
    speech_voice_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
