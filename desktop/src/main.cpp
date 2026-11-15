#include <wx/wx.h>
#include <wx/simplebook.h>
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
#include <wx/scrolwin.h>
#include <wx/dcbuffer.h>
#include <wx/clipbrd.h>
#include <wx/dataobj.h>
#include <functional>
#include <algorithm>
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

namespace Palette {
const wxColour canvas(20,28,30), panel(38,46,46), raised(49,59,59);
const wxColour text(239,245,243), muted(166,184,178), accent(71,196,156);
}

class DashboardCard : public wxPanel {
public:
    DashboardCard(wxWindow* parent) : wxPanel(parent) {
        SetBackgroundStyle(wxBG_STYLE_PAINT);
        SetBackgroundColour(Palette::panel);
        Bind(wxEVT_PAINT,[this](wxPaintEvent&) {
            wxAutoBufferedPaintDC dc(this);
            dc.SetBackground(wxBrush(GetParent()->GetBackgroundColour())); dc.Clear();
            dc.SetPen(wxPen(wxColour(57,70,66))); dc.SetBrush(wxBrush(Palette::panel));
            dc.DrawRoundedRectangle(GetClientRect().Deflate(1),FromDIP(12));
        });
    }
};

static wxStaticText* heading(wxWindow* parent, const wxString& title, int size=16) {
    auto* label=new wxStaticText(parent,wxID_ANY,title);
    label->SetFont(wxFontInfo(size).Bold()); label->SetForegroundColour(Palette::text);
    return label;
}
static void dashboardTheme(wxWindow* parent) {
    for(auto* child:parent->GetChildren()) {
        child->SetForegroundColour(Palette::text);
        if(dynamic_cast<wxTextCtrl*>(child)||dynamic_cast<wxListCtrl*>(child)) child->SetBackgroundColour(Palette::canvas);
        else if(dynamic_cast<wxButton*>(child)) child->SetBackgroundColour(Palette::raised);
        else child->SetBackgroundColour(parent->GetBackgroundColour());
        dashboardTheme(child);
    }
}

// Separate native buttons avoid the compact, embossed labels in the macOS
// notebook tab strip, while retaining keyboard and accessibility support.
class ServiceBook final : public wxSimplebook {
    wxWindow* tabParent_;
    wxBoxSizer* tabRow_;
    std::vector<wxButton*> tabs_;
public:
    ServiceBook(wxWindow* parent,wxWindow* tabParent,wxBoxSizer* row)
        : wxSimplebook(parent,wxID_ANY),tabParent_(tabParent),tabRow_(row) {}
    bool AddPage(wxWindow* page,const wxString& label,bool select=false,int imageId=-1) override {
        auto* button=new wxButton(tabParent_,wxID_ANY,label,wxDefaultPosition,wxDefaultSize,wxBORDER_NONE);
        button->SetFont(wxFontInfo(13));
        button->SetMinSize(button->FromDIP(wxSize(-1,36)));
        size_t index=tabs_.size();tabs_.push_back(button);
        tabRow_->Add(button,1,wxEXPAND|wxRIGHT,4);
        button->Bind(wxEVT_BUTTON,[this,index](wxCommandEvent&){SetSelection(index);});
        bool added=wxSimplebook::AddPage(page,label,select,imageId);
        RefreshTabs();return added;
    }
    int SetSelection(size_t page) override {
        int previous=wxSimplebook::SetSelection(page);RefreshTabs();return previous;
    }
    void RefreshTabs() {
        for(size_t i=0;i<tabs_.size();++i){
            bool selected=static_cast<int>(i)==GetSelection();
            tabs_[i]->SetBackgroundColour(selected?wxColour(38,89,74):Palette::panel);
            tabs_[i]->SetForegroundColour(selected?wxColour(220,255,241):Palette::text);
            tabs_[i]->SetName(tabs_[i]->GetLabel()+(selected?" (selected)":""));
            tabs_[i]->Refresh();
        }
    }
};

class Desktop final : public wxFrame {
    wxTextCtrl *address_, *log_, *printer_, *windowText_;
    wxStaticText *stats_, *receivedMetric_, *sentMetric_, *transactionMetric_, *connectionBadge_;
    std::array<wxStaticText*,8> channelBadges_;
    wxBoxSizer *tcpRow_, *serialRow_;
    wxPanel* mainPanel_;
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
    ServiceBook* services_;
    wxString terminalOutput_;
    bool terminalCursor_ = false;
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
    std::chrono::steady_clock::time_point lastStatusPoll_{};
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
        if (tcpRow_->AreAnyItemsShown() == serial || serialRow_->AreAnyItemsShown() != serial) {
            tcpRow_->ShowItems(!serial);
            serialRow_->ShowItems(serial);
            mainPanel_->Layout();
            if(auto* scroll=dynamic_cast<wxScrolledWindow*>(mainPanel_)) scroll->FitInside();
        }
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
        bool channelsChanged = state_.value("channels",json::array()) != state.value("channels",json::array());
        bool windowsChanged = state_.value("windows",json::array()) != state.value("windows",json::array());
        int newWindow=-1;
        const auto previousWindows=state_.value("windows",json::array());
        for(const auto& window:state.value("windows",json::array())) {
            int channel=window.value("channel",-1);
            if(channel<0 || !window.value("open",true)) continue;
            auto previous=std::find_if(previousWindows.begin(),previousWindows.end(),[channel](const json& item){return item.value("channel",-1)==channel && item.value("open",true);});
            if(previous==previousWindows.end()) newWindow=channel;
        }
        state_ = state;
        bool active = running(), connected = state_.value("connected", false);
        bool serial = stringValue(state_,"transport") == "serial";
        if (connected != wasConnected) appendLog(serial ? (connected ? "Serial port opened" : "Serial port closed") : (connected ? "Guest connected" : "Guest disconnected"));
        connectionControls(); root_->Enable(!active); verbose_->Enable(!active);
        start_->Enable(ready_ && !active && !starting_); stop_->Enable(active); disconnect_->Enable(active && connected);
        SetStatusText(!active ? wxS("Stopped") : serial ? (connected ? wxS("Serial port open") : wxS("Waiting for serial port")) : connected ? wxS("Guest connected") : wxS("Listening — waiting for guest"), 0);
        SetStatusText(active ? (serial ? text(stringValue(state_,"serialPath")) : text(stringValue(state_,"bind")) + wxString::Format(":%d",state_.value("port",0))) : "", 1);
        auto serialError = stringValue(state_,"serialError");
        if (serialError != lastSerialError_) { if (!serialError.empty()) appendLog("Serial: " + text(serialError) + " (retrying)"); lastSerialError_ = serialError; }
        auto metricValue=[](unsigned long long value) { return wxString::Format("%llu",value); };
        receivedMetric_->SetLabel(metricValue(state_.value("received",0ULL)));
        sentMetric_->SetLabel(metricValue(state_.value("sent",0ULL)));
        transactionMetric_->SetLabel(metricValue(state_.value("transactions",0ULL)));
        connectionBadge_->SetLabel(!active ? "SERVER STOPPED" : connected ? "CONNECTED" : "LISTENING");
        connectionBadge_->SetForegroundColour(active ? Palette::accent : Palette::muted);
        stats_->SetLabel(!active ? "Start the server to accept a connection." : serial ? "Serial transport  /  " + text(stringValue(state_,"serialPath")) : "TCP transport  /  " + text(stringValue(state_,"bind")) + wxString::Format(":%d",state_.value("port",0)));
        for (int i=0; i<4; ++i) {
            bool mounted = false;
            for (const auto& d : state_["disks"]) if (d.value("drive",-1)==i) {
                drives_[i].path->ChangeValue(text(stringValue(d,"path")));
                drives_[i].path->SetToolTip(text(stringValue(d,"path")));
                drives_[i].state->SetLabel(d.value("dirty",false) ? "Modified" : "Ready");
                drives_[i].state->SetForegroundColour(d.value("dirty",false) ? wxColour(245,185,94) : Palette::accent);
                mounted = true;
                break;
            }
            if (!mounted) { drives_[i].state->SetLabel("Empty"); drives_[i].state->SetForegroundColour(Palette::muted); drives_[i].path->UnsetToolTip(); if (ready_ && ticks_ > 3) drives_[i].path->Clear(); }
            drives_[i].mount->Enable(ready_ && !closing_); drives_[i].save->Enable(mounted && !closing_); drives_[i].saveAs->Enable(mounted && !closing_); drives_[i].eject->Enable(mounted && !closing_);
        }
        auto printer = state_.value("printer",json::object());
        auto preview = text(stringValue(printer,"text"));
        if (printer_->GetValue() != preview) printer_->ChangeValue(preview);
        if(channelsChanged) {
        for(int i=0;i<8;++i){channelBadges_[i]->SetLabel(wxString::Format("Channel %d  /  Idle",i+1));channelBadges_[i]->SetForegroundColour(Palette::muted);}
        channels_->DeleteAllItems();
        for (const auto& channel : state_.value("channels",json::array())) {
            int number=channel.value("channel",0);
            if(number>=1 && number<=8){
                bool open=channel.value("open",false);int pending=channel.value("pending",0);
                channelBadges_[number-1]->SetLabel(wxString::Format("Channel %d  /  ",number)+(channel.value("tcp",false)?wxString("TCP"):open?wxString("Open"):wxString("Idle"))+(pending?wxString::Format("  /  %d B",pending):wxString()));
                channelBadges_[number-1]->SetForegroundColour(open?Palette::accent:Palette::muted);
            }
            long row = channels_->InsertItem(channels_->GetItemCount(),wxString::Format("%d",channel.value("channel",0)));
            channels_->SetItem(row,1,channel.value("open",false) ? "Open" : "Closed");
            channels_->SetItem(row,2,channel.value("tcp",false) ? "TCP" : "Local");
            channels_->SetItem(row,3,wxString::Format("%d",channel.value("pending",0)));
        }
        }
        if(windowsChanged) {
        int selected = windowChoice_->GetSelection();
        int selectedChannel = selected == wxNOT_FOUND ? -1 : static_cast<int>(reinterpret_cast<intptr_t>(windowChoice_->GetClientData(selected)));
        if(newWindow>=0) selectedChannel=newWindow;
        windowChoice_->Clear();
        for (const auto& window : state_.value("windows",json::array())) {
            int channel = window.value("channel",128);
            auto index = windowChoice_->Append(text(stringValue(window,"title","Window")) + wxString::Format(" (%d)",channel-128), reinterpret_cast<void*>(static_cast<intptr_t>(channel)));
            if (channel == selectedChannel) windowChoice_->SetSelection(static_cast<int>(index));
        }
        if (windowChoice_->GetSelection() == wxNOT_FOUND && windowChoice_->GetCount()) windowChoice_->SetSelection(0);
        }
        windowChoice_->Enable(windowChoice_->GetCount()>0);
        if(newWindow>=0) {
            services_->SetSelection(0);
            Raise();
            // Native notebook activation can restore its own focus after
            // SetSelection; focus the terminal once that event completes.
            CallAfter([this,newWindow]{if(!closing_ && windowChannel()==newWindow) windowText_->SetFocus();});
        }
        showWindow();
    }
    int windowChannel() const {
        auto selection = windowChoice_->GetSelection();
        return selection == wxNOT_FOUND ? -1 : static_cast<int>(reinterpret_cast<intptr_t>(windowChoice_->GetClientData(selection)));
    }
    void showWindow() {
        int selected = windowChannel(); std::string value;
        for (const auto& w : state_.value("windows",json::array())) if (w.value("channel",-1)==selected) value = stringValue(w,"text");
        auto output=text(value);
        long selectionStart=0,selectionEnd=0;windowText_->GetSelection(&selectionStart,&selectionEnd);
        bool outputChanged=terminalOutput_!=output;
        bool cursor=selected>=0 && running() && wxWindow::FindFocus()==windowText_ && selectionStart==selectionEnd &&
            (std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()/500)%2==0;
        if(outputChanged || cursor!=terminalCursor_){
            int scroll=windowText_->GetScrollPos(wxVERTICAL);
            terminalOutput_=output;terminalCursor_=cursor;
            windowText_->ChangeValue(output+(cursor?wxString(wxUniChar(0x2588)):wxString()));
            if(outputChanged){windowText_->SetInsertionPointEnd();windowText_->ShowPosition(windowText_->GetLastPosition());}
            else {windowText_->SetSelection(selectionStart,selectionEnd);windowText_->SetScrollPos(wxVERTICAL,scroll);}
        }
        windowText_->SetToolTip(selected >= 0 && running() ? "Type directly here. Ctrl keys go to the guest; use the platform copy/paste shortcuts." : "Open a /Z device on the guest to begin an interactive session.");
    }
    void sendWindowInput(const wxString& input) {
        int channel=windowChannel();
        if(channel<0 || !running() || input.empty()) return;
        send({{"command","windowInput"},{"channel",channel},{"text",utf8(input)}});
    }
    void copyWindow() {
        long start=0,end=0;windowText_->GetSelection(&start,&end);
        // The block cursor is presentation only and must never enter copied text.
        end=std::min(end,static_cast<long>(terminalOutput_.length()));
        if(end<=start || !wxTheClipboard->Open()) return;
        wxTheClipboard->SetData(new wxTextDataObject(terminalOutput_.Mid(start,end-start)));
        wxTheClipboard->Close();
    }
    void pasteWindow() {
        if(!wxTheClipboard->Open()) return;
        wxTextDataObject data;
        bool available=wxTheClipboard->GetData(data);
        wxTheClipboard->Close();
        if(available){auto input=data.GetText();input.Replace("\r\n","\r");input.Replace("\n","\r");sendWindowInput(input);}
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
        // Use elapsed time rather than timer counts; retain backpressure when
        // the backend is busy so refresh requests cannot accumulate.
        auto refreshInterval = std::chrono::milliseconds(running() ? 100 : 500);
        if (ready_ && process_ && !closing_ && now-lastStatusPoll_ >= refreshInterval && !statusPending_) {
            lastStatusPoll_ = now;
            statusPending_ = true;
            send({{"command","status"}},[this](const json&) { statusPending_ = false; },true);
        }
        std::vector<long> expired;
        for (const auto& item : pending_) if (now - item.second.sent > std::chrono::seconds(15)) expired.push_back(item.first);
        for (auto id : expired) { auto quiet=pending_[id].quiet; pending_.erase(id); statusPending_=false; if (!quiet) error("The server did not respond to a command."); }
        showWindow();
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
    Desktop(wxString server, wxString smokeRoot) : wxFrame(nullptr,wxID_ANY,"DriveWire Swift Server",wxDefaultPosition,wxSize(1280,900)),
        timer_(this), executable_(server), smokeRoot_(smokeRoot), smoke_(!smokeRoot.empty()) {
        SetMinSize(FromDIP(wxSize(1100,720)));
        auto* menu = new wxMenuBar; auto* file = new wxMenu;
        file->Append(wxID_OPEN,wxS("&Open configuration…\tCtrl+O")); file->Append(wxID_SAVEAS,wxS("&Save configuration…\tCtrl+Shift+S"));
        file->AppendSeparator(); file->Append(wxID_EXIT,"&Quit\tCtrl+Q"); menu->Append(file,"&File");
        auto* serverMenu = new wxMenu; serverMenu->Append(1001,"Restart &backend"); serverMenu->Append(1002,"Save all disk changes\tCtrl+S"); menu->Append(serverMenu,"&Server");
        auto* help = new wxMenu; help->Append(wxID_ABOUT,"&About DriveWire Swift Server"); menu->Append(help,"&Help"); SetMenuBar(menu);
        CreateStatusBar(2); int widths[]={-1,230}; SetStatusWidths(2,widths);
        auto* panel = new wxPanel(this); auto* rootPanel=panel; mainPanel_ = panel; panel->SetBackgroundColour(Palette::canvas); auto* layout = new wxBoxSizer(wxVERTICAL);
        auto* header = new wxBoxSizer(wxHORIZONTAL);
        auto* branding = new wxBoxSizer(wxVERTICAL);
        auto* title = new wxStaticText(panel,wxID_ANY,"DriveWire Swift Server");
        title->SetFont(wxFontInfo(28).Bold());
        branding->Add(title);
        header->Add(branding,1,wxALIGN_CENTER_VERTICAL|wxRIGHT,16);
        connectionBadge_=heading(panel,"SERVER STOPPED",11);
        header->Add(connectionBadge_,0,wxALIGN_CENTER_VERTICAL|wxRIGHT,18);
        start_=new wxButton(panel,wxID_ANY,"Start server");
        stop_=new wxButton(panel,wxID_ANY,"Stop server");
        disconnect_=new wxButton(panel,wxID_ANY,"Disconnect guest");
        header->Add(start_,0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        header->Add(stop_,0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        header->Add(disconnect_,0,wxALIGN_CENTER_VERTICAL);
        start_->Disable();stop_->Disable();disconnect_->Disable();
        layout->Add(header,0,wxEXPAND|wxALL,18);
        auto* columns=new wxBoxSizer(wxHORIZONTAL);
        auto* left=new wxScrolledWindow(rootPanel); left->SetScrollRate(0,16); left->SetBackgroundColour(Palette::canvas);
        auto* leftLayout=new wxBoxSizer(wxVERTICAL);
        auto* connectionCard=new DashboardCard(left);
        panel=connectionCard; mainPanel_=left;
        auto* connection = new wxBoxSizer(wxVERTICAL);
        connection->Add(heading(panel,"Connection"),0,wxALL,14);
        auto* transportRow = new wxBoxSizer(wxHORIZONTAL);
        transportRow->Add(new wxStaticText(panel,wxID_ANY,"Transport"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        transport_=new wxChoice(panel,wxID_ANY);transport_->Append("TCP / Becker");transport_->Append("Serial port");transport_->SetSelection(0);transportRow->Add(transport_,0);
        connection->Add(transportRow,0,wxEXPAND|wxLEFT|wxRIGHT|wxTOP,10);
        auto* row = new wxBoxSizer(wxHORIZONTAL); tcpRow_ = row; row->Add(new wxStaticText(panel,wxID_ANY,"Listen address"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        address_ = new wxTextCtrl(panel,wxID_ANY,"127.0.0.1"); row->Add(address_,1,wxRIGHT,14);
        row->Add(new wxStaticText(panel,wxID_ANY,"Port"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        port_ = new wxSpinCtrl(panel,wxID_ANY,"65504",wxDefaultPosition,wxSize(95,-1),wxSP_ARROW_KEYS,0,65535,65504); row->Add(port_,0,wxRIGHT,14);
        verbose_ = new wxCheckBox(panel,wxID_ANY,"Trace wire bytes"); transportRow->AddStretchSpacer(); transportRow->Add(verbose_,0,wxALIGN_CENTER_VERTICAL);
        connection->Add(row,0,wxEXPAND|wxALL,10);
        auto* serialRow = new wxBoxSizer(wxHORIZONTAL); serialRow_ = serialRow;
        serialRow->Add(new wxStaticText(panel,wxID_ANY,"Serial port"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        serialPath_=new wxComboBox(panel,wxID_ANY);serialPath_->SetHint("COM3 or /dev/cu.usbserial...");serialRow->Add(serialPath_,1,wxRIGHT,8);
        refreshPorts_=new wxButton(panel,wxID_ANY,"Refresh");serialRow->Add(refreshPorts_,0,wxRIGHT,12);
        auto* serialSettings=new wxBoxSizer(wxHORIZONTAL);
        serialSettings->Add(new wxStaticText(panel,wxID_ANY,"Baud"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        baud_=new wxComboBox(panel,wxID_ANY,"57600",wxDefaultPosition,wxSize(100,-1));for(auto value:{"9600","19200","38400","57600","115200","230400"})baud_->Append(value);serialSettings->Add(baud_,0,wxRIGHT,10);
        dtr_=new wxCheckBox(panel,wxID_ANY,"DTR");dtr_->SetValue(true);serialSettings->Add(dtr_,0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        rts_=new wxCheckBox(panel,wxID_ANY,"RTS");rts_->SetValue(true);serialSettings->Add(rts_,0,wxALIGN_CENTER_VERTICAL);
        auto* serialGroup=new wxBoxSizer(wxVERTICAL); serialGroup->Add(serialRow,0,wxEXPAND|wxBOTTOM,8);serialGroup->Add(serialSettings,0,wxEXPAND);
        serialRow_=serialGroup;
        connection->Add(serialGroup,0,wxEXPAND|wxALL,10);
        auto* rootRow = new wxBoxSizer(wxHORIZONTAL); rootRow->Add(new wxStaticText(panel,wxID_ANY,"RFM root"),0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
        root_ = new wxDirPickerCtrl(panel,wxID_ANY,wxGetHomeDir(),"Choose RFM host root",wxDefaultPosition,wxDefaultSize,wxDIRP_DEFAULT_STYLE|wxDIRP_DIR_MUST_EXIST);
        rootRow->Add(root_,1); connection->Add(rootRow,0,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,10);
        connection->Add(new wxStaticText(panel,wxID_ANY,"Choose the folder containing OS9Boot and device folders (such as DD)."),0,wxLEFT|wxRIGHT|wxBOTTOM,10);
        connectionCard->SetSizer(connection); leftLayout->Add(connectionCard,0,wxEXPAND|wxBOTTOM,14);
        auto* right=new wxPanel(rootPanel); right->SetBackgroundColour(Palette::canvas); auto* rightLayout=new wxBoxSizer(wxVERTICAL);
        auto* activity=new DashboardCard(right); auto* activityLayout=new wxBoxSizer(wxVERTICAL);
        activityLayout->Add(heading(activity,"Activity"),0,wxALL,14);
        auto* metrics=new wxBoxSizer(wxHORIZONTAL);
        auto metric=[&](const wxString& label) {
            auto* tile=new wxPanel(activity);tile->SetBackgroundColour(Palette::raised);auto* tileLayout=new wxBoxSizer(wxVERTICAL);
            auto* value=heading(tile,"0",22);tileLayout->Add(value,0,wxALL,10);
            tileLayout->Add(new wxStaticText(tile,wxID_ANY,label),0,wxLEFT|wxRIGHT|wxBOTTOM,10);
            tile->SetSizer(tileLayout);metrics->Add(tile,1,wxEXPAND|wxRIGHT,8);return value;
        };
        receivedMetric_=metric("Received bytes");sentMetric_=metric("Sent bytes");transactionMetric_=metric("Transactions");
        activityLayout->Add(metrics,0,wxEXPAND|wxLEFT|wxRIGHT,14);
        stats_=new wxStaticText(activity,wxID_ANY,"Waiting for activity");activityLayout->Add(stats_,0,wxALL,14);
        activity->SetSizer(activityLayout);rightLayout->Add(activity,0,wxEXPAND|wxBOTTOM,14);
        auto* channelCard=new DashboardCard(right);auto* channelLayout=new wxBoxSizer(wxVERTICAL);
        channelLayout->Add(heading(channelCard,"Virtual channels"),0,wxALL,14);
        auto* channelGrid=new wxFlexGridSizer(4,2,8,16);channelGrid->AddGrowableCol(0);channelGrid->AddGrowableCol(1);
        for(int i=0;i<8;++i){channelBadges_[i]=new wxStaticText(channelCard,wxID_ANY,wxString::Format("Channel %d  /  Idle",i+1));channelGrid->Add(channelBadges_[i],1,wxEXPAND);}
        channelLayout->Add(channelGrid,0,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,14);channelCard->SetSizer(channelLayout);rightLayout->Add(channelCard,0,wxEXPAND|wxBOTTOM,14);
        rightLayout->Add(heading(right,"Guest services"),0,wxBOTTOM,10);
        auto* tabPanel=new wxPanel(right);auto* tabRow=new wxBoxSizer(wxHORIZONTAL);tabPanel->SetSizer(tabRow);
        rightLayout->Add(tabPanel,0,wxEXPAND|wxBOTTOM,10);
        auto* notebook = new ServiceBook(right,tabPanel,tabRow); services_=notebook; notebook->SetMinSize(wxSize(-1,250)); rightLayout->Add(notebook,1,wxEXPAND);
        auto* disks = new wxPanel(left); disks->SetBackgroundColour(Palette::canvas); auto* diskLayout = new wxBoxSizer(wxVERTICAL);
        diskLayout->Add(heading(disks,"Virtual disks"),0,wxLEFT|wxTOP,12);
        diskLayout->Add(new wxStaticText(disks,wxID_ANY,"Disk changes stay in memory until you save them."),0,wxALL,12);
        for (int i=0;i<4;++i) {
            auto* driveCard=new DashboardCard(disks);
            auto* box = new wxBoxSizer(wxVERTICAL);
            box->Add(heading(driveCard,wxString::Format("Drive %d",i),13),0,wxLEFT|wxRIGHT|wxTOP,12);
            auto& drive=drives_[i]; drive.path=new wxTextCtrl(driveCard,wxID_ANY,"",wxDefaultPosition,wxDefaultSize,wxTE_READONLY); drive.path->SetHint("No disk image mounted"); box->Add(drive.path,0,wxEXPAND|wxALL,8);
            auto* diskActions = new wxBoxSizer(wxHORIZONTAL);
            drive.state=new wxStaticText(driveCard,wxID_ANY,"Empty",wxDefaultPosition,FromDIP(wxSize(90,-1))); diskActions->Add(drive.state,0,wxALIGN_CENTER_VERTICAL|wxRIGHT,8);
            diskActions->AddStretchSpacer();
            drive.mount=new wxButton(driveCard,wxID_ANY,wxS("Mount…")); drive.save=new wxButton(driveCard,wxID_ANY,"Save"); drive.saveAs=new wxButton(driveCard,wxID_ANY,wxS("Save As…")); drive.eject=new wxButton(driveCard,wxID_ANY,"Eject");
            drive.save->Disable();drive.saveAs->Disable();drive.eject->Disable();
            diskActions->Add(drive.mount,0,wxRIGHT,8);diskActions->Add(drive.save,0,wxRIGHT,8);diskActions->Add(drive.saveAs,0,wxRIGHT,8);diskActions->Add(drive.eject);
            box->Add(diskActions,0,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,8);
            drive.mount->Bind(wxEVT_BUTTON,[this,i](wxCommandEvent&){mount(i);});
            drive.save->Bind(wxEVT_BUTTON,[this,i](wxCommandEvent&){saveDisk(i);});
            drive.saveAs->Bind(wxEVT_BUTTON,[this,i](wxCommandEvent&){saveDisk(i,true);});
            drive.save->Bind(wxEVT_CONTEXT_MENU,[this,i](wxContextMenuEvent&){saveDisk(i,true);});
            drive.save->SetToolTip("Save guest changes. Right-click to Save As.");
            drive.eject->Bind(wxEVT_BUTTON,[this,i](wxCommandEvent&){preserve(i,[this,i](bool save,bool discard){send({{"command","eject"},{"drive",i},{"saveBefore",save},{"discard",discard}},[this](const json& r){if(r.value("ok",false))remember();});});});
            driveCard->SetSizer(box);diskLayout->Add(driveCard,0,wxEXPAND|wxBOTTOM,10);
        }
        disks->SetSizer(diskLayout);leftLayout->Add(disks,0,wxEXPAND);
        left->SetSizer(leftLayout);left->FitInside();right->SetSizer(rightLayout);
        columns->Add(left,1,wxEXPAND|wxRIGHT,16);columns->Add(right,1,wxEXPAND);
        layout->Add(columns,1,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,18);
        auto* windows=new wxPanel(notebook);auto* windowsLayout=new wxBoxSizer(wxVERTICAL);
        windowChoice_=new wxChoice(windows,wxID_ANY); windowsLayout->Add(windowChoice_,0,wxEXPAND|wxALL,8);
        windowText_=new wxTextCtrl(windows,wxID_ANY,"",wxDefaultPosition,wxDefaultSize,
            wxTE_MULTILINE|wxTE_READONLY|wxTE_DONTWRAP|wxHSCROLL|wxTE_PROCESS_ENTER|wxTE_PROCESS_TAB|wxWANTS_CHARS);
        windowText_->SetFont(wxFontInfo(13).Family(wxFONTFAMILY_TELETYPE));
        windowText_->SetHint("No active virtual windows. Open /Z1 on the guest, then click here to type.");
        windowsLayout->Add(windowText_,1,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,8);
        windowText_->Bind(wxEVT_KEY_DOWN,[this](wxKeyEvent& event){
            int key=event.GetKeyCode();
#ifdef __WXOSX__
            bool shortcut=event.CmdDown();
#else
            bool shortcut=event.ControlDown() && event.ShiftDown();
#endif
            if(shortcut){
                if(key=='V'){pasteWindow();return;}
                if(key=='C'){copyWindow();return;}
                if(key=='A'){windowText_->SelectAll();return;}
                event.Skip();return;
            }
            if(event.RawControlDown() && !event.AltDown()) {
                if(key>='A' && key<='_'){sendWindowInput(wxString(wxUniChar(key & 31)));return;}
                if(key==WXK_SPACE){sendWindowInput(wxString(wxUniChar(0)));return;}
            }
            switch(key){
                case WXK_RETURN: case WXK_NUMPAD_ENTER: sendWindowInput("\r");return;
                case WXK_BACK: sendWindowInput("\b");return;
                case WXK_TAB: if(event.ShiftDown()){windowText_->Navigate(wxNavigationKeyEvent::IsBackward);return;} sendWindowInput("\t");return;
                case WXK_ESCAPE: sendWindowInput(wxString(wxUniChar(27)));return;
                case WXK_DELETE: sendWindowInput(wxString(wxUniChar(127)));return;
                case WXK_LEFT: sendWindowInput("\b");return;
                case WXK_RIGHT: sendWindowInput("\t");return;
                case WXK_DOWN: sendWindowInput("\n");return;
                case WXK_UP: sendWindowInput(wxString(wxUniChar(12)));return;
                default: event.Skip();
            }
        });
        windowText_->Bind(wxEVT_CHAR,[this](wxKeyEvent& event){
            int key=event.GetUnicodeKey();
            if(key>=32 && key<=126) sendWindowInput(wxString(wxUniChar(key)));
        });
        windowText_->Bind(wxEVT_TEXT_COPY,[this](wxClipboardTextEvent&){copyWindow();});
        windowText_->Bind(wxEVT_TEXT_PASTE,[this](wxClipboardTextEvent&){pasteWindow();});
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
        rootPanel->SetSizer(layout); dashboardTheme(rootPanel); notebook->RefreshTabs(); connectionBadge_->SetForegroundColour(Palette::accent);
        transport_->Bind(wxEVT_CHOICE,[this](wxCommandEvent&){connectionControls();if(ready_&&transport_->GetSelection()==1)refreshPorts();});
        refreshPorts_->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){refreshPorts();});
        start_->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){start();});stop_->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){send({{"command","stop"}});});
        disconnect_->Bind(wxEVT_BUTTON,[this](wxCommandEvent&){send({{"command","disconnect"}});});
        windowChoice_->Bind(wxEVT_CHOICE,[this](wxCommandEvent&){showWindow();windowText_->SetFocus();});
        Bind(wxEVT_MENU,[this](wxCommandEvent&){configuration(false);},wxID_OPEN);Bind(wxEVT_MENU,[this](wxCommandEvent&){configuration(true);},wxID_SAVEAS);
        Bind(wxEVT_MENU,[this](wxCommandEvent&){Close();},wxID_EXIT);Bind(wxEVT_MENU,[this](wxCommandEvent&){send({{"command","saveAll"}});},1002);
        Bind(wxEVT_MENU,[this](wxCommandEvent&){if(process_){error("Stop and quit normally before restarting a running backend.");return;}launch();},1001);
        Bind(wxEVT_MENU,[this](wxCommandEvent&){wxAboutDialogInfo info;info.SetName("DriveWire Swift Server");info.SetVersion("0.2.0");info.SetDescription("A wxWidgets desktop for the shared Swift DriveWire server.\nThe native Swift Mac application remains a separate application.");info.SetWebSite("https://github.com/DrPitre/DriveWire");wxAboutBox(info,this);},wxID_ABOUT);
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
        services_->SetSelection(3);
        unsigned char window[]={0x45,129,0xC3,129,'>'};smokeSocket_->Write(window,sizeof(window));
        send({{"command","status"}});
    } else if(step==4) {
        if(!dirty(0)){failSmoke("Guest write did not mark disk modified");return;}
        if(transport_->GetSelection()==0 && (windowChannel()!=129 || wxWindow::FindFocus()!=windowText_)){--smokeStep_;return;}
        if(transport_->GetSelection()==0){
            if(windowChannel()!=129 || services_->GetSelection()!=0 || wxWindow::FindFocus()!=windowText_){failSmoke("New virtual window did not receive focus");return;}
            stop_->SetFocus();auto unchanged=state_;update(unchanged);
            if(wxWindow::FindFocus()!=stop_){failSmoke("Routine status update stole focus");return;}
            windowText_->SetFocus();
            wxKeyEvent character(wxEVT_CHAR);character.m_uniChar='x';character.m_keyCode='X';windowText_->GetEventHandler()->ProcessEvent(character);
            for(int key:std::array<int,5>{WXK_RETURN,WXK_BACK,'C',WXK_TAB,WXK_ESCAPE}){
                wxKeyEvent event(wxEVT_KEY_DOWN);event.m_keyCode=key;event.SetRawControlDown(key=='C');windowText_->GetEventHandler()->ProcessEvent(event);
            }
            if(terminalOutput_!=">"){failSmoke("Terminal input must wait for guest echo");return;}
        }
        wxCommandEvent event(wxEVT_BUTTON,drives_[0].save->GetId());drives_[0].save->GetEventHandler()->ProcessEvent(event);
    } else if(step==5) {
        if(dirty(0)){failSmoke("GUI save left disk dirty");return;}
        if(transport_->GetSelection()==0){
            unsigned char request[]={0x63,129,6},actual[6]={};const unsigned char expected[]={'x',13,8,3,9,27};
            smokeSocket_->Write(request,sizeof(request));smokeSocket_->Read(actual,sizeof(actual));
            if(smokeSocket_->LastCount()!=sizeof(actual)||!std::equal(std::begin(actual),std::end(actual),std::begin(expected))){failSmoke("Direct terminal keystrokes did not reach guest intact");return;}
        }
        bool missing=wxFileExists(smokeRoot_+"/serial-missing.txt");
        wxFileInputStream image(smokeRoot_+wxS("/disk ü.dsk"));unsigned char b=0;image.Read(&b,1);
        if(!image.IsOk()||b!=(missing?0:0x41)){failSmoke("GUI Save did not persist guest bytes");return;}
        if(smokeSocket_){
            services_->SetSelection(2);
            unsigned char window[]={0xC4,18,0x29,0xC3,130,'2'};
            smokeSocket_->Write(window,sizeof(window));
            send({{"command","status"}});
            return;
        }
    } else if(step==6) {
        if(transport_->GetSelection()==0){
            if(windowChannel()!=130 || wxWindow::FindFocus()!=windowText_){--smokeStep_;return;}
            if(services_->GetSelection()!=0 || windowChoice_->GetCount()!=2){failSmoke("Z2 did not become selected with Z1 open");return;}
            smokeSocket_->Close();
        }
        wxCommandEvent event(wxEVT_BUTTON,stop_->GetId());stop_->GetEventHandler()->ProcessEvent(event);
    } else if(step==7) {
        if(running()){failSmoke("GUI Stop did not stop listener");return;}
        send({{"command","eject"},{"drive",0}});
    } else if(step==8) {
        if(!state_["disks"].empty()){failSmoke("Eject did not clear mounted disk");return;}
        json checks;
        if (wxFileExists(smokeRoot_+"/serial-missing.txt")) checks={"serial selection", "manual COM port", "port refresh", "start button", "missing-port waiting state", "stop cancels retries", "eject", "graceful shutdown"};
        else checks={"backend launch", "configuration", "Unicode disk path", "start button", transport_->GetSelection()==1?"serial DWINIT":"TCP DWINIT", "direct terminal input and control keys", "new Z2 selection and focus with Z1 open", "guest sector write", "dirty tracking", "save button", "persisted bytes", "stop button", "eject", "graceful shutdown"};
        wxFileOutputStream file(smokeRoot_+"/ui-result.json");auto result=json({{"ok",true},{"checks",checks}}).dump(2);file.Write(result.data(),result.size());
        shutdown();
    }
}

class Application final : public wxApp {
    int result_=0;
public:
    bool OnInit() override {
        SetAppName("DriveWire Swift Server");SetVendorName("DriveWire");
        wxCmdLineParser parser(argc,argv);parser.AddOption("","server","Path to the Swift drivewire-server executable");parser.AddOption("","smoke-test","Run the desktop integration test using this prepared directory");parser.AddSwitch("h","help","Show help",wxCMD_LINE_OPTION_HELP);
        if(parser.Parse()!=0)return false;
        wxString server,smoke;parser.Found("server",&server);parser.Found("smoke-test",&smoke);
        auto* frame=new Desktop(server,smoke);frame->Bind(wxEVT_DESTROY,[this,frame](wxWindowDestroyEvent& event){if(event.GetEventObject()==frame)result_=frame->exitCode();event.Skip();});
        frame->Show();SetTopWindow(frame);return true;
    }
    int OnExit() override { return result_; }
};
wxIMPLEMENT_APP(Application);
