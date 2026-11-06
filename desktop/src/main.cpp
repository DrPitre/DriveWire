#include <wx/wx.h>
#include <wx/notebook.h>
#include <wx/filepicker.h>
#include <wx/spinctrl.h>
#include <wx/listctrl.h>
#include <wx/process.h>
#include <wx/stdpaths.h>
#include <wx/filename.h>
#include <wx/fileconf.h>
#include <wx/wfstream.h>
#include <wx/socket.h>
#include <wx/aboutdlg.h>
#include <wx/cmdline.h>
#include <wx/combobox.h>
#include <functional>
#include <map>
#include <array>
#include <chrono>
#include <memory>
#include "json.hpp"

using json = nlohmann::json;
static std::string utf8(const wxString& s) { return s.ToStdString(wxConvUTF8); }
static wxString text(const std::string& s) { return wxString::FromUTF8(s.c_str()); }
static std::string stringValue(const json& j, const char* key, const std::string& fallback = "") {
    return j.contains(key) && j[key].is_string() ? j[key].get<std::string>() : fallback;
}

class Desktop final : public wxFrame {
    wxTextCtrl *address_, *log_, *printer_, *windowText_, *windowInput_;
    wxStaticText* stats_;
    wxSpinCtrl* port_;
    wxChoice* transport_;
    wxComboBox *serialPath_, *baud_;
    wxCheckBox *dtr_, *rts_;
    wxButton* refreshPorts_;
    std::string lastSerialError_;
    wxDirPickerCtrl* root_;
    wxCheckBox* verbose_;
    wxButton *start_, *stop_, *disconnect_;
    wxChoice* windowChoice_;
    wxListCtrl* channels_;
    struct DriveRow { wxTextCtrl* path; wxStaticText* state; wxButton *mount, *eject, *save, *saveAs; };
    std::array<DriveRow, 4> drives_;
    wxTimer timer_;
    wxProcess* process_ = nullptr;
    long pid_ = 0;
    wxString executable_, smokeRoot_;
    std::string stdoutBuffer_, stderrBuffer_;
    json state_ = json::object();
    long nextID_ = 1;
    struct Pending { std::function<void(const json&)> callback; std::chrono::steady_clock::time_point sent; bool quiet; };
    std::map<long, Pending> pending_;
    int ticks_ = 0;
    bool ready_ = false, closing_ = false, statusPending_ = false, starting_ = false;
    bool smoke_ = false;
    int smokeStep_ = 0, exitCode_ = 0;
    std::chrono::steady_clock::time_point launched_ = std::chrono::steady_clock::now();
    std::unique_ptr<wxSocketClient> smokeSocket_;
    wxFileConfig preferences_{"DriveWire Desktop", "DriveWire"};

    wxTextCtrl* multiline(wxWindow* parent) {
        auto* control = new wxTextCtrl(parent, wxID_ANY, "", wxDefaultPosition, wxDefaultSize,
                                      wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP | wxHSCROLL);
        control->SetFont(wxFontInfo(11).Family(wxFONTFAMILY_TELETYPE));
        return control;
    }
    void appendLog(const wxString& message) {
        if (message.empty()) return;
        if (log_->GetLastPosition() > 150000) log_->Remove(0, 50000);
        log_->AppendText(message.EndsWith("\n") ? message : message + "\n");
    }
    void error(const wxString& message) {
        appendLog("Error: " + message);
        SetStatusText(message, 0);
        if (smoke_) { failSmoke(utf8(message)); return; }
        CallAfter([this, message] { if (!closing_) wxMessageBox(message, "DriveWire", wxOK | wxICON_ERROR, this); });
    }
    wxString defaultServer() {
        wxFileName binary(wxStandardPaths::Get().GetExecutablePath());
#ifdef __WXMSW__
        binary.SetFullName("drivewire-server.exe");
#else
        binary.SetFullName("drivewire-server");
#endif
        return binary.GetFullPath();
    }
    bool running() const { return state_.value("running", false); }
    bool dirty(int number = -1) const {
        for (const auto& disk : state_.value("disks", json::array()))
            if ((number < 0 || disk.value("drive", -1) == number) && disk.value("dirty", false)) return true;
        return false;
    }
    void send(json request, std::function<void(const json&)> callback = {}, bool quiet = false) {
        if (!process_ || !ready_) { if (!quiet) error("The server is not available. Use Server > Restart backend."); return; }
        long id = nextID_++;
        request["id"] = id;
        auto data = request.dump() + "\n";
        pending_[id] = {std::move(callback), std::chrono::steady_clock::now(), quiet};
        auto* stream = process_->GetOutputStream();
        stream->Write(data.data(), data.size());
        if (!stream->IsOk()) { pending_.erase(id); error("Unable to write to the server process."); }
    }
    void parseLine(const std::string& line) {
        auto marker = line.find("@drivewire ");
        if (marker == std::string::npos) { if (!line.empty()) appendLog(text(line)); return; }
        try {
            auto reply = json::parse(line.substr(marker + 11));
            if (reply.value("protocol", 0) != 1) { error("Unsupported server control protocol."); return; }
            if (!ready_) { ready_ = true; SetStatusText("Server ready", 0); startup(); }
            if (reply.contains("state")) update(reply["state"]);
            auto found = pending_.find(reply.value("id", 0L));
            if (found != pending_.end()) {
                auto pending = std::move(found->second);
                pending_.erase(found);
                if (!reply.value("ok", false)) {
                    if (!pending.quiet) error(text(stringValue(reply, "error", "Server operation failed")));
                }
                // Dialog callbacks may run a nested event loop. Dispatch them
                // after pipe draining so they cannot re-enter its line buffer.
                if (pending.callback) CallAfter([callback = std::move(pending.callback), reply] { callback(reply); });
            }
        } catch (const std::exception& e) { appendLog("Invalid server response: " + text(e.what())); }
    }
    void drain(wxInputStream* stream, std::string& buffer, bool protocol) {
        if (!stream) return;
        // Bounded work per tick keeps the UI responsive during verbose traffic.
        size_t count = 0;
        while (stream->CanRead() && count++ < 65536) {
            char byte; stream->Read(&byte, 1);
            if (!stream->LastRead()) break;
            if (byte == '\n') {
                auto line = std::move(buffer);
                buffer.clear();
                if (protocol) parseLine(line); else if (!line.empty()) appendLog(text(line));
            } else if (byte != '\r') buffer += byte;
            if (buffer.size() > 2 * 1024 * 1024) { buffer.clear(); appendLog("Oversized server log line omitted"); }
        }
    }
    void launch() {
        if (process_) return;
        ready_ = false; closing_ = false; starting_ = false; launched_ = std::chrono::steady_clock::now();
        wxString path = executable_.empty() ? defaultServer() : executable_;
        if (!wxFileExists(path)) {
            if (smoke_) { failSmoke("Server executable not found: " + utf8(path)); return; }
            wxFileDialog choose(this, "Locate drivewire-server", "", "", wxFileSelectorDefaultWildcardStr, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
            if (choose.ShowModal() != wxID_OK) { SetStatusText("Select a server with Server > Restart backend", 0); return; }
            path = executable_ = choose.GetPath();
        }
        process_ = new wxProcess(this);
        process_->Redirect();
        // Use argv, never shell quoting: spaces and Unicode paths stay intact.
        const wxChar* args[] = {path.wc_str(), wxS("--managed"), nullptr};
        pid_ = wxExecute(args, wxEXEC_ASYNC | wxEXEC_HIDE_CONSOLE, process_);
        if (!pid_) { delete process_; process_ = nullptr; error("Could not launch " + path); return; }
        appendLog("Backend: " + path);
        SetStatusText(wxS("Starting server process…"), 0);
    }
    json settings() const {
        long baud = 0; baud_->GetValue().ToLong(&baud);
        return {{"bind", utf8(address_->GetValue())}, {"port", port_->GetValue()},
                {"transport", transport_->GetSelection() == 1 ? "serial" : "tcp"},
                {"serialPath", utf8(serialPath_->GetValue())}, {"baud", baud},
                {"dtr", dtr_->GetValue()}, {"rts", rts_->GetValue()},
                {"root", utf8(root_->GetPath())}, {"verbose", verbose_->GetValue()}};
    }
    void connectionControls() {
        bool active = running(), serial = transport_->GetSelection() == 1;
        transport_->Enable(!active);
        address_->Enable(!active && !serial); port_->Enable(!active && !serial);
        serialPath_->Enable(!active && serial); baud_->Enable(!active && serial);
        dtr_->Enable(!active && serial); rts_->Enable(!active && serial);
        refreshPorts_->Enable(ready_ && !active && serial);
    }
    void refreshPorts() {
        send({{"command", "ports"}}, [this](const json& reply) {
            if (!reply.value("ok", false)) return;
            auto current = serialPath_->GetValue();
            serialPath_->Clear();
            for (const auto& path : reply.value("ports", json::array())) serialPath_->Append(text(path.get<std::string>()));
            serialPath_->SetValue(current);
            if (current.empty() && serialPath_->GetCount()) serialPath_->SetSelection(0);
        });
    }
    void startup() {
        if (smoke_) { smokeTick(); return; }
        refreshPorts();
        auto config = settings(); config["command"] = "configure"; send(config);
        for (int i = 0; i < 4; ++i) {
            auto path = drives_[i].path->GetValue();
            if (!path.empty()) send({{"command", "mount"}, {"drive", i}, {"path", utf8(path)}});
        }
    }
    void remember() {
        if (smoke_) return;
        preferences_.Write("transport", static_cast<long>(transport_->GetSelection()));
        preferences_.Write("serialPath", serialPath_->GetValue());
        preferences_.Write("baud", baud_->GetValue());
        preferences_.Write("dtr", dtr_->GetValue()); preferences_.Write("rts", rts_->GetValue());
        preferences_.Write("bind", address_->GetValue());
        preferences_.Write("port", static_cast<long>(port_->GetValue()));
        preferences_.Write("root", root_->GetPath());
        preferences_.Write("verbose", verbose_->GetValue());
        preferences_.Write("server", executable_);
        for (int i=0; i<4; ++i) preferences_.Write(wxString::Format("disk%d", i), drives_[i].path->GetValue());
        preferences_.Flush();
    }
    void start() {
        if (running() || starting_) return;
        starting_ = true; start_->Disable();
        auto request = settings(); request["command"] = "configure";
        send(request, [this](const json& reply) {
            starting_ = false;
            if (reply.value("ok", false)) send({{"command", "start"}}, [this](const json& result) {
                if (result.value("ok", false)) { remember(); appendLog("Server started"); }
            });
        });
    }
    void preserve(int number, std::function<void(bool, bool)> continuation) {
        send({{"command", "status"}}, [this, number, continuation](const json& reply) {
            if (!reply.value("ok", false)) return;
            if (!dirty(number)) { continuation(false, false); return; }
            auto answer = wxMessageBox("This disk has guest changes. Save them before continuing?", "Unsaved disk changes",
                                       wxYES_NO | wxCANCEL | wxICON_QUESTION, this);
            if (answer == wxCANCEL) return;
            // Saving and replacing happen in one backend command, so guest
            // writes cannot slip between Save and Eject/Mount.
            continuation(answer == wxYES, answer == wxNO);
        });
    }
    void mount(int number) {
        wxFileDialog choose(this, wxString::Format("Mount image in drive %d", number), "", "",
                            "Disk images (*.dsk;*.vhd;*.os9)|*.dsk;*.vhd;*.os9|All files|*", wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        if (choose.ShowModal() != wxID_OK) return;
        auto path = utf8(choose.GetPath());
        preserve(number, [this, number, path](bool save, bool discard) {
            send({{"command", "mount"}, {"drive", number}, {"path", path}, {"saveBefore", save}, {"discard", discard}},
                 [this](const json& r) { if (r.value("ok", false)) remember(); });
        });
    }
    void saveDisk(int number, bool saveAs = false) {
        json request = {{"command", "save"}, {"drive", number}};
        if (saveAs) {
            wxFileDialog choose(this, "Save disk image as", "", wxFileName(drives_[number].path->GetValue()).GetFullName(),
                                "Disk images (*.dsk)|*.dsk|All files|*", wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
            if (choose.ShowModal() != wxID_OK) return;
            request["path"] = utf8(choose.GetPath());
        }
        send(request, [this, number](const json& r) { if (r.value("ok", false)) { appendLog(wxString::Format("Saved drive %d", number)); remember(); } });
    }
    void exportLog() {
        wxFileDialog choose(this, "Save log", "", "drivewire.log", "Text files|*.log;*.txt|All files|*", wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
        if (choose.ShowModal() == wxID_OK && !log_->SaveFile(choose.GetPath())) error("Could not write the log file.");
    }
    void configuration(bool save) {
        if (!save && running()) { error("Stop the server before loading a configuration."); return; }
        if (!save && dirty()) { error("Save or eject changed disks before loading a configuration."); return; }
        wxFileDialog choose(this, save ? "Save configuration" : "Open configuration", "", "DriveWire.json",
                            "DriveWire configurations|*.json", save ? wxFD_SAVE | wxFD_OVERWRITE_PROMPT : wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        if (choose.ShowModal() != wxID_OK) return;
        try {
            if (save) {
                auto object = settings(); object["version"] = 1; object["disks"] = json::array();
                for (int i=0; i<4; ++i) object["disks"].push_back(utf8(drives_[i].path->GetValue()));
                wxFileOutputStream output(choose.GetPath()); auto data = object.dump(2) + "\n";
                output.Write(data.data(), data.size()); if (!output.IsOk()) throw std::runtime_error("Could not write configuration");
            } else {
                wxFileInputStream input(choose.GetPath()); std::string content;
                while (input.CanRead()) { char b[4096]; input.Read(b,sizeof(b)); content.append(b,input.LastRead()); }
                auto object = json::parse(content);
                if (object.value("version", 0) != 1) throw std::runtime_error("Unsupported configuration version");
                auto disks = object.at("disks").get<std::vector<std::string>>();
                if (disks.size() != 4) throw std::runtime_error("Configuration must have four drives");
                auto address = object.at("bind").get<std::string>(); auto root = object.at("root").get<std::string>();
                auto port = object.at("port").get<int>(); auto verbose = object.at("verbose").get<bool>();
                auto transport = object.value("transport", std::string("tcp"));
                auto serialPath = object.value("serialPath", std::string()); auto baud = object.value("baud",57600);
                if ((transport != "tcp" && transport != "serial") || baud < 300 || baud > 1000000 || (transport == "serial" && serialPath.empty())) throw std::runtime_error("Invalid serial settings");
                if (address.empty() || port < 0 || port > 65535 || !wxDirExists(text(root))) throw std::runtime_error("Invalid connection settings or RFM root");
                for (const auto& disk : disks) if (!disk.empty() && !wxFileExists(text(disk))) throw std::runtime_error("Disk image not found: " + disk);
                transport_->SetSelection(transport == "serial" ? 1 : 0); serialPath_->SetValue(text(serialPath));
                baud_->SetValue(wxString::Format("%d",baud)); dtr_->SetValue(object.value("dtr",true)); rts_->SetValue(object.value("rts",true));
                connectionControls();
                address_->ChangeValue(text(address)); root_->SetPath(text(root)); port_->SetValue(port); verbose_->SetValue(verbose);
                for (int i=0; i<4; ++i) {
                    send({{"command", "eject"}, {"drive", i}});
                    drives_[i].path->ChangeValue(text(disks[i]));
                    if (!disks[i].empty()) send({{"command", "mount"}, {"drive", i}, {"path", disks[i]}});
                }
                auto request = settings(); request["command"] = "configure"; send(request);
                remember();
            }
        } catch (const std::exception& e) { error(text(e.what())); }
    }
    void update(const json& state) {
        bool wasConnected = state_.value("connected", false);
        state_ = state;
        bool active = running(), connected = state_.value("connected", false);
        if (connected != wasConnected) appendLog(connected ? "Guest connected" : "Guest disconnected");
        connectionControls(); root_->Enable(!active); verbose_->Enable(!active);
        start_->Enable(ready_ && !active && !starting_); stop_->Enable(active); disconnect_->Enable(active && connected);
        bool serial = stringValue(state_,"transport") == "serial";
        SetStatusText(!active ? wxS("Stopped") : connected ? wxS("Guest connected") : serial ? wxS("Waiting for serial port") : wxS("Listening — waiting for guest"), 0);
        SetStatusText(active ? (serial ? text(stringValue(state_,"serialPath")) : text(stringValue(state_,"bind")) + wxString::Format(":%d",state_.value("port",0))) : "", 1);
        auto serialError = stringValue(state_,"serialError");
        if (serialError != lastSerialError_) { if (!serialError.empty()) appendLog("Serial: " + text(serialError) + " (retrying)"); lastSerialError_ = serialError; }
        stats_->SetLabel(wxString::Format("Received: %llu bytes     Sent: %llu bytes     Transactions: %llu",
            static_cast<unsigned long long>(state_.value("received", 0ULL)),
            static_cast<unsigned long long>(state_.value("sent", 0ULL)),
            static_cast<unsigned long long>(state_.value("transactions", 0ULL))));
        for (int i=0; i<4; ++i) {
            bool mounted = false;
            for (const auto& d : state_["disks"]) if (d.value("drive",-1)==i) {
                drives_[i].path->ChangeValue(text(stringValue(d,"path")));
                drives_[i].state->SetLabel(d.value("dirty",false) ? "Modified" : "Ready");
                mounted = true;
                break;
            }
            if (!mounted) { drives_[i].state->SetLabel("Empty"); if (ready_ && ticks_ > 3) drives_[i].path->Clear(); }
            drives_[i].mount->Enable(ready_ && !closing_); drives_[i].save->Enable(mounted && !closing_); drives_[i].saveAs->Enable(mounted && !closing_); drives_[i].eject->Enable(mounted && !closing_);
        }
        auto printer = state_.value("printer",json::object());
        auto preview = text(stringValue(printer,"text"));
        if (printer_->GetValue() != preview) printer_->ChangeValue(preview);
        channels_->DeleteAllItems();
        for (const auto& channel : state_.value("channels",json::array())) {
            long row = channels_->InsertItem(channels_->GetItemCount(),wxString::Format("%d",channel.value("channel",0)));
            channels_->SetItem(row,1,channel.value("open",false) ? "Open" : "Closed");
            channels_->SetItem(row,2,channel.value("tcp",false) ? "TCP" : "Local");
            channels_->SetItem(row,3,wxString::Format("%d",channel.value("pending",0)));
        }
        int selected = windowChoice_->GetSelection();
        int selectedChannel = selected == wxNOT_FOUND ? -1 : static_cast<int>(reinterpret_cast<intptr_t>(windowChoice_->GetClientData(selected)));
        windowChoice_->Clear();
        for (const auto& window : state_.value("windows",json::array())) {
            int channel = window.value("channel",128);
            auto index = windowChoice_->Append(text(stringValue(window,"title","Window")) + wxString::Format(" (%d)",channel-128), reinterpret_cast<void*>(static_cast<intptr_t>(channel)));
            if (channel == selectedChannel) windowChoice_->SetSelection(static_cast<int>(index));
        }
        if (windowChoice_->GetSelection() == wxNOT_FOUND && windowChoice_->GetCount()) windowChoice_->SetSelection(0);
        showWindow();
    }
    int windowChannel() const {
        auto selection = windowChoice_->GetSelection();
        return selection == wxNOT_FOUND ? -1 : static_cast<int>(reinterpret_cast<intptr_t>(windowChoice_->GetClientData(selection)));
    }
    void showWindow() {
        int selected = windowChannel(); std::string value;
        for (const auto& w : state_.value("windows",json::array())) if (w.value("channel",-1)==selected) value = stringValue(w,"text");
        auto display = text(value); if (windowText_->GetValue() != display) { windowText_->ChangeValue(display); windowText_->ShowPosition(windowText_->GetLastPosition()); }
        windowInput_->Enable(selected >= 0 && running());
    }
    void close() {
        if (closing_) return;
        if (!process_ || !ready_) { Destroy(); return; }
        send({{"command", "status"}}, [this](const json& reply) {
            if (!reply.value("ok", false)) return;
            if (dirty()) {
                auto answer = wxMessageBox("Save all guest disk changes before quitting?", "Quit DriveWire", wxYES_NO | wxCANCEL | wxICON_QUESTION,this);
                if (answer == wxCANCEL) return;
                shutdown(answer == wxYES, answer == wxNO);
            } else shutdown();
        });
    }
    void shutdown(bool save = false, bool discard = false) {
        closing_ = true;
        remember();
        send({{"command","shutdown"},{"saveBefore",save},{"discard",discard}}, [this](const json& reply) {
            if (reply.value("ok",false)) { if (process_) process_->CloseOutput(); }
            else closing_ = false;
        });
        SetStatusText(wxS("Closing server…"),0);
    }
    void onTimer(wxTimerEvent&) {
        ++ticks_;
        if (process_) {
            drain(process_->GetInputStream(),stdoutBuffer_,true);
            drain(process_->GetErrorStream(),stderrBuffer_,false);
        }
        auto now = std::chrono::steady_clock::now();
        if (process_ && !ready_ && now - launched_ > std::chrono::seconds(20)) {
            ready_ = true; error("The backend did not complete startup. Check its log and runtime libraries.");
        }
        if (ready_ && process_ && !closing_ && ticks_ % 20 == 0 && !statusPending_) {
            statusPending_ = true;
            send({{"command","status"}},[this](const json&) { statusPending_ = false; },true);
        }
        std::vector<long> expired;
        for (const auto& item : pending_) if (now - item.second.sent > std::chrono::seconds(15)) expired.push_back(item.first);
        for (auto id : expired) { auto quiet=pending_[id].quiet; pending_.erase(id); statusPending_=false; if (!quiet) error("The server did not respond to a command."); }
        if (smoke_) smokeTick();
    }
    void onExit(wxProcessEvent& event) {
        if (process_) {
            drain(process_->GetInputStream(),stdoutBuffer_,true); drain(process_->GetErrorStream(),stderrBuffer_,false);
            delete process_; process_=nullptr;
        }
        pid_=0; ready_=false; starting_=false; pending_.clear(); statusPending_=false;
        if (closing_) { Destroy(); return; }
        start_->Disable(); stop_->Disable(); disconnect_->Disable();
        SetStatusText(wxString::Format("Backend stopped (exit %d)",event.GetExitCode()),0);
        appendLog("Backend exited. Use Server > Restart backend to reconnect.");
        if (smoke_) failSmoke("Unexpected backend exit");
    }
    void failSmoke(const std::string& message) {
        if (exitCode_ != 0) return;
        exitCode_=1;
        wxFileOutputStream out(smokeRoot_ + "/ui-result.json"); auto result = json({{"ok",false},{"error",message},{"step",smokeStep_},{"log",utf8(log_->GetValue())}}).dump(2); out.Write(result.data(), result.size());
        closing_=true;
        if (process_) { process_->CloseOutput(); wxProcess::Kill(static_cast<int>(pid_),wxSIGKILL,wxKILL_CHILDREN); }
        CallAfter([this] { Destroy(); });
    }
    void smokeTick();
public:
    Desktop(wxString server, wxString smokeRoot) : wxFrame(nullptr,wxID_ANY,"DriveWire Desktop",wxDefaultPosition,wxSize(1040,860)),
        timer_(this), executable_(server), smokeRoot_(smokeRoot), smoke_(!smokeRoot.empty()) {
        SetMinSize(wxSize(820,760));
        auto* menu = new wxMenuBar; auto* file = new wxMenu;
        file->Append(wxID_OPEN,wxS("&Open configuration…\tCtrl+O")); file->Append(wxID_SAVEAS,wxS("&Save configuration…\tCtrl+Shift+S"));
        file->AppendSeparator(); file->Append(wxID_EXIT,"&Quit\tCtrl+Q"); menu->Append(file,"&File");
        auto* serverMenu = new wxMenu; serverMenu->Append(1001,"Restart &backend"); serverMenu->Append(1002,"Save all disk changes\tCtrl+S"); menu->Append(serverMenu,"&Server");
        auto* help = new wxMenu; help->Append(wxID_ABOUT,"&About DriveWire Desktop"); menu->Append(help,"&Help"); SetMenuBar(menu);
        CreateStatusBar(2); int widths[]={-1,230}; SetStatusWidths(2,widths);
        auto* panel = new wxPanel(this); auto* layout = new wxBoxSizer(wxVERTICAL);
        auto* title = new wxStaticText(panel,wxID_ANY,"DriveWire"); title->SetFont(wxFontInfo(23).Bold()); layout->Add(title,0,wxLEFT|wxTOP,18);
        layout->Add(new wxStaticText(panel,wxID_ANY,wxS("TCP / serial server • RFM • virtual disks")),0,wxLEFT|wxBOTTOM,18);
        auto* connection = new wxStaticBoxSizer(wxVERTICAL,panel,"Connection");
        auto* transportRow = new wxBoxSizer(wxHORIZONTAL);
        transportRow->Add(new wxStaticText(panel,wxID_ANY,"Transport"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        transport_=new wxChoice(panel,wxID_ANY);transport_->Append("TCP / Becker");transport_->Append("Serial port");transport_->SetSelection(0);transportRow->Add(transport_,0);
        connection->Add(transportRow,0,wxEXPAND|wxLEFT|wxRIGHT|wxTOP,10);
        auto* row = new wxBoxSizer(wxHORIZONTAL); row->Add(new wxStaticText(panel,wxID_ANY,"Listen address"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        address_ = new wxTextCtrl(panel,wxID_ANY,"127.0.0.1"); row->Add(address_,1,wxRIGHT,14);
        row->Add(new wxStaticText(panel,wxID_ANY,"Port"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        port_ = new wxSpinCtrl(panel,wxID_ANY,"65504",wxDefaultPosition,wxSize(140,-1),wxSP_ARROW_KEYS,0,65535,65504); row->Add(port_,0,wxRIGHT,14);
        verbose_ = new wxCheckBox(panel,wxID_ANY,"Trace wire bytes"); row->Add(verbose_,0,wxALIGN_CENTER_VERTICAL);
        connection->Add(row,0,wxEXPAND|wxALL,10);
        auto* serialRow = new wxBoxSizer(wxHORIZONTAL);
        serialRow->Add(new wxStaticText(panel,wxID_ANY,"Serial port"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        serialPath_=new wxComboBox(panel,wxID_ANY);serialPath_->SetHint("COM3 or /dev/cu.usbserial...");serialRow->Add(serialPath_,1,wxRIGHT,8);
        refreshPorts_=new wxButton(panel,wxID_ANY,"Refresh");serialRow->Add(refreshPorts_,0,wxRIGHT,12);
        serialRow->Add(new wxStaticText(panel,wxID_ANY,"Baud"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        baud_=new wxComboBox(panel,wxID_ANY,"57600",wxDefaultPosition,wxSize(125,-1));for(auto value:{"9600","19200","38400","57600","115200","230400"})baud_->Append(value);serialRow->Add(baud_,0,wxRIGHT,10);
        dtr_=new wxCheckBox(panel,wxID_ANY,"DTR");dtr_->SetValue(true);serialRow->Add(dtr_,0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        rts_=new wxCheckBox(panel,wxID_ANY,"RTS");rts_->SetValue(true);serialRow->Add(rts_,0,wxALIGN_CENTER_VERTICAL);
        connection->Add(serialRow,0,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,10);
        auto* rootRow = new wxBoxSizer(wxHORIZONTAL); rootRow->Add(new wxStaticText(panel,wxID_ANY,"RFM root"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        root_ = new wxDirPickerCtrl(panel,wxID_ANY,wxGetHomeDir(),"Choose RFM host root",wxDefaultPosition,wxDefaultSize,wxDIRP_DEFAULT_STYLE|wxDIRP_DIR_MUST_EXIST);
        rootRow->Add(root_,1); connection->Add(rootRow,0,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,10);
        connection->Add(new wxStaticText(panel,wxID_ANY,"RFM root contains OS9Boot and device folders such as DD. Stop to change connection settings."),0,wxLEFT|wxRIGHT|wxBOTTOM,10);
        auto* actions = new wxBoxSizer(wxHORIZONTAL);
        start_=new wxButton(panel,wxID_ANY,"Start server"); stop_=new wxButton(panel,wxID_ANY,"Stop server"); disconnect_=new wxButton(panel,wxID_ANY,"Disconnect guest");
        actions->Add(start_,0,wxRIGHT,8); actions->Add(stop_,0,wxRIGHT,8); actions->Add(disconnect_,0);
        start_->Disable();stop_->Disable();disconnect_->Disable(); connection->Add(actions,0,wxLEFT|wxRIGHT|wxBOTTOM,10);
        stats_=new wxStaticText(panel,wxID_ANY,"No traffic"); connection->Add(stats_,0,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,10);
        layout->Add(connection,0,wxEXPAND|wxLEFT|wxRIGHT,18);
        auto* notebook = new wxNotebook(panel,wxID_ANY); layout->Add(notebook,1,wxEXPAND|wxALL,18);
        auto* disks = new wxPanel(notebook); auto* diskLayout = new wxBoxSizer(wxVERTICAL);
        diskLayout->Add(new wxStaticText(disks,wxID_ANY,"Guest writes stay in memory until saved. Save changed disks before ejecting or quitting."),0,wxALL,12);
        for (int i=0;i<4;++i) {
            auto* box = new wxStaticBoxSizer(wxHORIZONTAL,disks,wxString::Format("Drive %d",i));
            auto& drive=drives_[i]; drive.path=new wxTextCtrl(disks,wxID_ANY,"",wxDefaultPosition,wxDefaultSize,wxTE_READONLY); box->Add(drive.path,1,wxALIGN_CENTER_VERTICAL|wxALL,6);
            drive.state=new wxStaticText(disks,wxID_ANY,"Empty",wxDefaultPosition,wxSize(66,-1)); box->Add(drive.state,0,wxALIGN_CENTER_VERTICAL|wxRIGHT,6);
            drive.mount=new wxButton(disks,wxID_ANY,wxS("Mount…")); drive.save=new wxButton(disks,wxID_ANY,"Save"); drive.saveAs=new wxButton(disks,wxID_ANY,wxS("Save As…")); drive.eject=new wxButton(disks,wxID_ANY,"Eject");
            box->Add(drive.mount,0,wxALL,4);box->Add(drive.save,0,wxALL,4);box->Add(drive.saveAs,0,wxALL,4);box->Add(drive.eject,0,wxALL,4);
            drive.mount->Bind(wxEVT_BUTTON,[this,i](wxCommandEvent&){mount(i);});
            drive.save->Bind(wxEVT_BUTTON,[this,i](wxCommandEvent&){saveDisk(i);});
            drive.saveAs->Bind(wxEVT_BUTTON,[this,i](wxCommandEvent&){saveDisk(i,true);});
            drive.save->Bind(wxEVT_CONTEXT_MENU,[this,i](wxContextMenuEvent&){saveDisk(i,true);});
            drive.save->SetToolTip("Save guest changes. Right-click to Save As.");
            drive.eject->Bind(wxEVT_BUTTON,[this,i](wxCommandEvent&){preserve(i,[this,i](bool save,bool discard){send({{"command","eject"},{"drive",i},{"saveBefore",save},{"discard",discard}},[this](const json& r){if(r.value("ok",false))remember();});});});
            diskLayout->Add(box,0,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,12);
        }
        disks->SetSizer(diskLayout);notebook->AddPage(disks,"Disks");
        auto* windows=new wxPanel(notebook);auto* windowsLayout=new wxBoxSizer(wxVERTICAL);
        windowChoice_=new wxChoice(windows,wxID_ANY); windowsLayout->Add(windowChoice_,0,wxEXPAND|wxALL,8);
        windowText_=multiline(windows);windowsLayout->Add(windowText_,1,wxEXPAND|wxLEFT|wxRIGHT,8);
        windowInput_=new wxTextCtrl(windows,wxID_ANY,"",wxDefaultPosition,wxDefaultSize,wxTE_PROCESS_ENTER);windowInput_->SetHint("Enter a line to send to the selected virtual window");windowsLayout->Add(windowInput_,0,wxEXPAND|wxALL,8);
        windows->SetSizer(windowsLayout);notebook->AddPage(windows,"Virtual windows");
        auto* ports=new wxPanel(notebook);auto* portsLayout=new wxBoxSizer(wxVERTICAL);channels_=new wxListCtrl(ports,wxID_ANY,wxDefaultPosition,wxDefaultSize,wxLC_REPORT);
        channels_->InsertColumn(0,"Channel",wxLIST_FORMAT_LEFT,110);channels_->InsertColumn(1,"State",wxLIST_FORMAT_LEFT,120);channels_->InsertColumn(2,"Transport",wxLIST_FORMAT_LEFT,130);channels_->InsertColumn(3,"Pending bytes",wxLIST_FORMAT_LEFT,140);
        portsLayout->Add(channels_,1,wxEXPAND|wxALL,8);ports->SetSizer(portsLayout);notebook->AddPage(ports,"Serial channels");
        auto* printing=new wxPanel(notebook);auto* printLayout=new wxBoxSizer(wxVERTICAL);
        printLayout->Add(new wxStaticText(printing,wxID_ANY,"Guest printer preview. Save the received text to a file."),0,wxALL,8);printer_=multiline(printing);printLayout->Add(printer_,1,wxEXPAND|wxLEFT|wxRIGHT,8);
        auto* savePrint=new wxButton(printing,wxID_ANY,wxS("Save preview…"));printLayout->Add(savePrint,0,wxALL,8);
        savePrint->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){wxFileDialog d(this,"Save printer preview","","DriveWire-print.txt","Text files|*.txt|All files|*",wxFD_SAVE|wxFD_OVERWRITE_PROMPT);if(d.ShowModal()==wxID_OK&&!printer_->SaveFile(d.GetPath()))error("Could not save printer preview.");});
        printing->SetSizer(printLayout);notebook->AddPage(printing,"Printer");
        auto* logging=new wxPanel(notebook);auto* logLayout=new wxBoxSizer(wxVERTICAL);log_=multiline(logging);logLayout->Add(log_,1,wxEXPAND|wxALL,8);
        auto* logActions=new wxBoxSizer(wxHORIZONTAL);auto* clearLog=new wxButton(logging,wxID_ANY,"Clear");auto* saveLog=new wxButton(logging,wxID_ANY,wxS("Save log…"));logActions->Add(clearLog,0,wxRIGHT,8);logActions->Add(saveLog);logLayout->Add(logActions,0,wxLEFT|wxRIGHT|wxBOTTOM,8);
        clearLog->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){log_->Clear();});saveLog->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){exportLog();});logging->SetSizer(logLayout);notebook->AddPage(logging,"Log");
        panel->SetSizer(layout);
        transport_->Bind(wxEVT_CHOICE,[this](wxCommandEvent&){connectionControls();if(ready_&&transport_->GetSelection()==1)refreshPorts();});
        refreshPorts_->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){refreshPorts();});
        start_->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){start();});stop_->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){send({{"command","stop"}});});
        disconnect_->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){send({{"command","disconnect"}});});
        windowChoice_->Bind(wxEVT_CHOICE,[this](wxCommandEvent&){showWindow();});windowInput_->Bind(wxEVT_TEXT_ENTER,[this](wxCommandEvent&){int channel=windowChannel();if(channel>=0){send({{"command","windowInput"},{"channel",channel},{"text",utf8(windowInput_->GetValue())+"\r"}});windowInput_->Clear();}});
        Bind(wxEVT_MENU,[this](wxCommandEvent&){configuration(false);},wxID_OPEN);Bind(wxEVT_MENU,[this](wxCommandEvent&){configuration(true);},wxID_SAVEAS);
        Bind(wxEVT_MENU,[this](wxCommandEvent&){Close();},wxID_EXIT);Bind(wxEVT_MENU,[this](wxCommandEvent&){send({{"command","saveAll"}});},1002);
        Bind(wxEVT_MENU,[this](wxCommandEvent&){if(process_){error("Stop and quit normally before restarting a running backend.");return;}launch();},1001);
        Bind(wxEVT_MENU,[this](wxCommandEvent&){wxAboutDialogInfo info;info.SetName("DriveWire Desktop");info.SetVersion("0.2.0");info.SetDescription("A wxWidgets desktop for the shared Swift DriveWire server.\nThe native Swift Mac application remains a separate application.");info.SetWebSite("https://github.com/DrPitre/DriveWire");wxAboutBox(info,this);},wxID_ABOUT);
        Bind(wxEVT_CLOSE_WINDOW,[this](wxCloseEvent& e){if(!e.CanVeto()){if(process_)process_->CloseOutput();Destroy();return;}e.Veto();close();});
        Bind(wxEVT_END_PROCESS,&Desktop::onExit,this);Bind(wxEVT_TIMER,&Desktop::onTimer,this);
        if (!smoke_) {
            transport_->SetSelection(preferences_.ReadLong("transport",0)==1?1:0);
            serialPath_->SetValue(preferences_.Read("serialPath",""));baud_->SetValue(preferences_.Read("baud","57600"));
            dtr_->SetValue(preferences_.ReadBool("dtr",true));rts_->SetValue(preferences_.ReadBool("rts",true));
            address_->ChangeValue(preferences_.Read("bind","127.0.0.1"));port_->SetValue(static_cast<int>(preferences_.ReadLong("port",65504)));
            root_->SetPath(preferences_.Read("root",wxGetHomeDir()));verbose_->SetValue(preferences_.ReadBool("verbose",false));
            if(executable_.empty())executable_=preferences_.Read("server","");
            for(int i=0;i<4;++i)drives_[i].path->ChangeValue(preferences_.Read(wxString::Format("disk%d",i),""));
        }
        connectionControls();
        timer_.Start(50);CallAfter([this]{launch();});
    }
    ~Desktop() override {
        timer_.Stop();
        if (process_) { process_->CloseOutput(); process_->Detach(); }
        wxTheApp->SetExitOnFrameDelete(true);
    }
    int exitCode() const { return exitCode_; }
};

void Desktop::smokeTick() {
    if (exitCode_ || closing_) return;
    if (std::chrono::steady_clock::now()-launched_ > std::chrono::seconds(60)) { failSmoke("Desktop smoke test timed out at step " + std::to_string(smokeStep_));return; }
    if (!ready_ || !pending_.empty()) return;
    auto step=smokeStep_++;
    if(step==0) {
        root_->SetPath(smokeRoot_);port_->SetValue(0);address_->ChangeValue("127.0.0.1");
        if (wxFileExists(smokeRoot_+"/serial-port.txt")) {
            wxFileInputStream input(smokeRoot_+"/serial-port.txt");std::string path;while(input.CanRead()){char b;input.Read(&b,1);if(input.LastRead())path+=b;}
            transport_->SetSelection(1);serialPath_->SetValue(text(path));baud_->SetValue("57600");connectionControls();
            wxCommandEvent refresh(wxEVT_BUTTON,refreshPorts_->GetId());refreshPorts_->GetEventHandler()->ProcessEvent(refresh);
        }
        auto config=settings();config["command"]="configure";send(config);
    } else if(step==1) {
        send({{"command","mount"},{"drive",0},{"path",utf8(smokeRoot_+wxS("/disk ü.dsk"))}});
    } else if(step==2) {
        wxCommandEvent event(wxEVT_BUTTON,start_->GetId());start_->GetEventHandler()->ProcessEvent(event);
    } else if(step==3) {
        if(!running()) { --smokeStep_;return; }
        if (transport_->GetSelection()==1) {
            if (wxFileExists(smokeRoot_+"/serial-missing.txt")) {
                if (state_.value("connected",false)||stringValue(state_,"serialError").empty()) { --smokeStep_;return; }
                smokeStep_=5;return;
            }
            if (state_.value("connected",false) && !wxFileExists(smokeRoot_+"/serial-ready")) { wxFileOutputStream ready(smokeRoot_+"/serial-ready");ready.Write("ready",5); }
            if (!dirty(0)||!wxFileExists(smokeRoot_+"/serial-guest-ok")) { --smokeStep_;return; }
            return;
        }
        smokeSocket_=std::make_unique<wxSocketClient>();smokeSocket_->SetTimeout(3);
        wxIPV4address endpoint;endpoint.Hostname("127.0.0.1");endpoint.Service(static_cast<unsigned short>(state_.value("port",0)));
        if(!smokeSocket_->Connect(endpoint,true)) {failSmoke("GUI-started server did not accept TCP");return;}
        unsigned char init[]={0x5a,1};smokeSocket_->Write(init,2);unsigned char reply=0;smokeSocket_->Read(&reply,1);
        if(smokeSocket_->LastCount()!=1||reply!=255){failSmoke("GUI-started server failed DWINIT");return;}
        // OP_WRITE: drive, LSN, 256 bytes, checksum; guest sector persists via GUI Save.
        std::vector<unsigned char> packet={0x57,0,0,0,0};packet.insert(packet.end(),256,0x41);packet.push_back(0x41);packet.push_back(0x00);
        smokeSocket_->Write(packet.data(),static_cast<wxUint32>(packet.size()));smokeSocket_->Read(&reply,1);
        if(smokeSocket_->LastCount()!=1||reply!=0){failSmoke("GUI mounted disk failed guest write");return;}
        send({{"command","status"}});
    } else if(step==4) {
        if(!dirty(0)){failSmoke("Guest write did not mark disk modified");return;}
        wxCommandEvent event(wxEVT_BUTTON,drives_[0].save->GetId());drives_[0].save->GetEventHandler()->ProcessEvent(event);
    } else if(step==5) {
        if(dirty(0)){failSmoke("GUI save left disk dirty");return;}
        bool missing=wxFileExists(smokeRoot_+"/serial-missing.txt");
        wxFileInputStream image(smokeRoot_+wxS("/disk ü.dsk"));unsigned char b=0;image.Read(&b,1);
        if(!image.IsOk()||b!=(missing?0:0x41)){failSmoke("GUI Save did not persist guest bytes");return;}
        if(smokeSocket_)smokeSocket_->Close();
        wxCommandEvent event(wxEVT_BUTTON,stop_->GetId());stop_->GetEventHandler()->ProcessEvent(event);
    } else if(step==6) {
        if(running()){failSmoke("GUI Stop did not stop listener");return;}
        send({{"command","eject"},{"drive",0}});
    } else if(step==7) {
        if(!state_["disks"].empty()){failSmoke("Eject did not clear mounted disk");return;}
        json checks;
        if (wxFileExists(smokeRoot_+"/serial-missing.txt")) checks={"serial selection", "manual COM port", "port refresh", "start button", "missing-port waiting state", "stop cancels retries", "eject", "graceful shutdown"};
        else checks={"backend launch", "configuration", "Unicode disk path", "start button", transport_->GetSelection()==1?"serial DWINIT":"TCP DWINIT", "guest sector write", "dirty tracking", "save button", "persisted bytes", "stop button", "eject", "graceful shutdown"};
        wxFileOutputStream file(smokeRoot_+"/ui-result.json");auto result=json({{"ok",true},{"checks",checks}}).dump(2);file.Write(result.data(),result.size());
        shutdown();
    }
}

class Application final : public wxApp {
    int result_=0;
public:
    bool OnInit() override {
        SetAppName("DriveWire Desktop");SetVendorName("DriveWire");
        wxCmdLineParser parser(argc,argv);parser.AddOption("","server","Path to the Swift drivewire-server executable");parser.AddOption("","smoke-test","Run the desktop integration test using this prepared directory");parser.AddSwitch("h","help","Show help",wxCMD_LINE_OPTION_HELP);
        if(parser.Parse()!=0)return false;
        wxString server,smoke;parser.Found("server",&server);parser.Found("smoke-test",&smoke);
        auto* frame=new Desktop(server,smoke);frame->Bind(wxEVT_DESTROY,[this,frame](wxWindowDestroyEvent& event){if(event.GetEventObject()==frame)result_=frame->exitCode();event.Skip();});
        frame->Show();SetTopWindow(frame);return true;
    }
    int OnExit() override { return result_; }
};
wxIMPLEMENT_APP(Application);
