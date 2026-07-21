#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gdesktopappinfo.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static constexpr char kCallbackMimeType[] =
    "x-scheme-handler/erebrusdrop";
static constexpr char kDesktopFileName[] = "com.erebrus.drop.desktop";

static gchar* my_application_icon_path() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", NULL);
  if (exe == NULL) {
    return NULL;
  }
  g_autofree gchar* dir = g_path_get_dirname(exe);
  return g_build_filename(dir, "data", "icons", "app_icon.png", NULL);
}

static void my_application_apply_icon(GtkWindow* window) {
  g_autofree gchar* icon_path = my_application_icon_path();
  if (icon_path == NULL || !g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
    return;
  }
  gtk_window_set_icon_from_file(window, icon_path, NULL);
}

// Register erebrusdrop:// for this user so the browser can return an
// authentication callback to the app. Keeping the executable path in the
// desktop entry also makes relocatable Flutter bundles work after being moved.
static void my_application_register_url_scheme() {
  g_autofree gchar* executable_path =
      g_file_read_link("/proc/self/exe", nullptr);
  if (executable_path == nullptr) {
    return;
  }

  g_autofree gchar* applications_dir =
      g_build_filename(g_get_user_data_dir(), "applications", nullptr);
  if (g_mkdir_with_parents(applications_dir, 0755) != 0) {
    g_warning("Failed to create the user applications directory");
    return;
  }

  g_autofree gchar* desktop_file_path =
      g_build_filename(applications_dir, kDesktopFileName, nullptr);
  g_autofree gchar* escaped_executable =
      g_strescape(executable_path, nullptr);
  g_autofree gchar* icon_path = my_application_icon_path();
  g_autofree gchar* escaped_icon =
      icon_path == nullptr ? nullptr : g_strescape(icon_path, nullptr);
  g_autofree gchar* desktop_entry = g_strdup_printf(
      "[Desktop Entry]\n"
      "Name=Erebrus Drop\n"
      "Comment=Private peer-to-peer file sharing\n"
      "Exec=\"%s\" %%u\n"
      "Icon=%s\n"
      "Terminal=false\n"
      "Type=Application\n"
      "Categories=Utility;Network;\n"
      "MimeType=%s;\n"
      "StartupWMClass=%s\n",
      escaped_executable, escaped_icon == nullptr ? "" : escaped_icon,
      kCallbackMimeType, APPLICATION_ID);

  g_autoptr(GError) write_error = nullptr;
  if (!g_file_set_contents(desktop_file_path, desktop_entry, -1,
                           &write_error)) {
    g_warning("Failed to register the Erebrus Drop URL handler: %s",
              write_error->message);
    return;
  }

  g_autoptr(GDesktopAppInfo) app_info =
      g_desktop_app_info_new(kDesktopFileName);
  if (app_info == nullptr) {
    g_warning("Failed to load the Erebrus Drop desktop entry");
    return;
  }

  g_autoptr(GError) default_error = nullptr;
  if (!g_app_info_set_as_default_for_type(G_APP_INFO(app_info),
                                           kCallbackMimeType,
                                           &default_error)) {
    g_warning("Failed to make Erebrus Drop the URL handler: %s",
              default_error->message);
  }
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Erebrus Drop");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Erebrus Drop");
  }

  gtk_window_set_default_size(window, 880, 820);
  my_application_apply_icon(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  // Allow GApplication to forward the command line to the primary process.
  // app_links_linux receives that signal and sends the callback into Dart.
  return FALSE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);

  my_application_register_url_scheme();

  g_autofree gchar* icon_path = my_application_icon_path();
  if (icon_path != NULL && g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
    gtk_window_set_default_icon_from_file(icon_path, NULL);
  }
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE |
                                         G_APPLICATION_HANDLES_OPEN,
                                     nullptr));
}
