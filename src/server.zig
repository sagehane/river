const std = @import("std");
const c = @import("c.zig").c;

const Output = @import("output.zig").Output;
const Root = @import("root.zig").Root;
const Seat = @import("seat.zig").Seat;
const View = @import("view.zig").View;

pub const Server = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,

    root: Root,
    seat: Seat,

    wl_display: *c.wl_display,
    wlr_backend: *c.wlr_backend,
    wlr_renderer: *c.wlr_renderer,

    listen_new_output: c.wl_listener,

    wlr_xdg_shell: *c.wlr_xdg_shell,
    listen_new_xdg_surface: c.wl_listener,

    pub fn init(self: *Self, allocator: *std.mem.Allocator) !void {
        self.allocator = allocator;

        // The Wayland display is managed by libwayland. It handles accepting
        // clients from the Unix socket, manging Wayland globals, and so on.
        self.wl_display = c.wl_display_create() orelse
            return error.CantCreateWlDisplay;
        errdefer c.wl_display_destroy(self.wl_display);

        // The wlr_backend abstracts the input/output hardware. Autocreate chooses
        // the best option based on the environment, for example DRM when run from
        // a tty or wayland if WAYLAND_DISPLAY is set.
        //
        // This frees itself.when the wl_display is destroyed.
        self.wlr_backend = c.zag_wlr_backend_autocreate(self.wl_display) orelse
            return error.CantCreateWlrBackend;

        // If we don't provide a renderer, autocreate makes a GLES2 renderer for us.
        // The renderer is responsible for defining the various pixel formats it
        // supports for shared memory, this configures that for clients.
        self.wlr_renderer = c.zag_wlr_backend_get_renderer(self.wlr_backend) orelse
            return error.CantGetWlrRenderer;
        // TODO: Handle failure after https://github.com/swaywm/wlroots/pull/2080
        c.wlr_renderer_init_wl_display(self.wlr_renderer, self.wl_display); // orelse
        //    return error.CantInitWlDisplay;

        // These both free themselves when the wl_display is destroyed
        _ = c.wlr_compositor_create(self.wl_display, self.wlr_renderer) orelse
            return error.CantCreateWlrCompositor;
        _ = c.wlr_data_device_manager_create(self.wl_display) orelse
            return error.CantCreateWlrDataDeviceManager;

        self.wlr_xdg_shell = c.wlr_xdg_shell_create(self.wl_display) orelse
            return error.CantCreateWlrXdgShell;

        try self.root.init(self);

        self.seat = try Seat.create(self);
        try self.seat.init();

        // Register our listeners for new outputs and xdg_surfaces.
        self.listen_new_output.notify = handle_new_output;
        c.wl_signal_add(&self.wlr_backend.events.new_output, &self.listen_new_output);

        self.listen_new_xdg_surface.notify = handle_new_xdg_surface;
        c.wl_signal_add(&self.wlr_xdg_shell.events.new_surface, &self.listen_new_xdg_surface);
    }

    /// Free allocated memory and clean up
    pub fn destroy(self: *Self) void {
        c.wl_display_destroy_clients(self.wl_display);
        c.wl_display_destroy(self.wl_display);
        self.root.destroy();
    }

    /// Create the socket, set WAYLAND_DISPLAY, and start the backend
    pub fn start(self: Self) !void {
        // Add a Unix socket to the Wayland display.
        const socket = c.wl_display_add_socket_auto(self.wl_display) orelse
            return error.CantAddSocket;

        // Start the backend. This will enumerate outputs and inputs, become the DRM
        // master, etc
        if (!c.zag_wlr_backend_start(self.wlr_backend)) {
            return error.CantStartBackend;
        }

        // Set the WAYLAND_DISPLAY environment variable to our socket and run the
        // startup command if requested. */
        if (c.setenv("WAYLAND_DISPLAY", socket, 1) == -1) {
            return error.CantSetEnv;
        }
    }

    /// Enter the wayland event loop and block until the compositor is exited
    pub fn run(self: Self) void {
        c.wl_display_run(self.wl_display);
    }

    pub fn handle_keybinding(self: *Self, sym: c.xkb_keysym_t) bool {
        // Here we handle compositor keybindings. This is when the compositor is
        // processing keys, rather than passing them on to the client for its own
        // processing.
        //
        // This function assumes the proper modifier is held down.
        switch (sym) {
            c.XKB_KEY_Escape => c.wl_display_terminate(self.wl_display),
            c.XKB_KEY_F1 => {
                // Cycle to the next view
                //if (c.wl_list_length(&server.views) > 1) {
                //    const current_view = @fieldParentPtr(View, "link", server.views.next);
                //    const next_view = @fieldParentPtr(View, "link", current_view.link.next);
                //    focus_view(next_view, next_view.xdg_surface.surface);
                //    // Move the previous view to the end of the list
                //    c.wl_list_remove(&current_view.link);
                //    c.wl_list_insert(server.views.prev, &current_view.link);
                //}
            },
            else => return false,
        }
        return true;
    }

    fn handle_new_output(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        const server = @fieldParentPtr(Server, "listen_new_output", listener.?);
        const wlr_output = @ptrCast(*c.wlr_output, @alignCast(@alignOf(*c.wlr_output), data));
        server.root.addOutput(wlr_output);
    }

    fn handle_new_xdg_surface(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This event is raised when wlr_xdg_shell receives a new xdg surface from a
        // client, either a toplevel (application window) or popup.
        const server = @fieldParentPtr(Server, "listen_new_xdg_surface", listener.?);
        const wlr_xdg_surface = @ptrCast(*c.wlr_xdg_surface, @alignCast(@alignOf(*c.wlr_xdg_surface), data));

        if (wlr_xdg_surface.role != c.enum_wlr_xdg_surface_role.WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
            // TODO: log
            return;
        }

        // toplevel surfaces are tracked and managed by the root
        server.root.addView(wlr_xdg_surface);
    }
};
