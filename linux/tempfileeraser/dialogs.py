"""Message and confirmation dialogs.

Gtk.AlertDialog only arrived in GTK 4.10. Ubuntu 22.04 ships 4.6, so the older
Gtk.MessageDialog is used there: deprecated from 4.10 but present everywhere the
tool supports. Both paths are asynchronous, as every GTK 4 dialog is.
"""

from __future__ import annotations

from typing import Callable

import gi

gi.require_version('Gtk', '4.0')
from gi.repository import Gio, GLib, Gtk  # noqa: E402 - must follow require_version

HAS_ALERT_DIALOG = hasattr(Gtk, 'AlertDialog')

_MESSAGE_TYPES = {
    'information': Gtk.MessageType.INFO,
    'warning': Gtk.MessageType.WARNING,
    'error': Gtk.MessageType.ERROR,
    'question': Gtk.MessageType.QUESTION,
}


def _split(text: str) -> tuple[str, str | None]:
    """First line as the heading, the rest as the detail below it."""
    heading, separator, detail = text.partition('\n')
    return heading, detail.strip() if separator else None


def show_message(text: str, icon: str = 'information', parent: Gtk.Window | None = None,
                 on_close: Callable[[], None] | None = None) -> None:
    heading, detail = _split(text)

    def finished(*_args) -> None:
        if on_close:
            on_close()

    if HAS_ALERT_DIALOG:
        dialog = Gtk.AlertDialog(message=heading, buttons=['OK'])
        if detail:
            dialog.set_detail(detail)
        dialog.choose(parent, None, lambda *_: finished())
        return

    dialog = Gtk.MessageDialog(transient_for=parent, modal=parent is not None,
                               message_type=_MESSAGE_TYPES.get(icon, Gtk.MessageType.INFO),
                               buttons=Gtk.ButtonsType.OK, text=heading)
    if detail:
        dialog.props.secondary_text = detail
    dialog.connect('response', lambda widget, _response: (widget.destroy(), finished()))
    dialog.present()


def confirm(text: str, on_response: Callable[[bool], None], confirm_label: str = 'Erase',
            parent: Gtk.Window | None = None, destructive: bool = True) -> None:
    """Asks a yes/no question. Cancel is always the default, as on Windows."""
    heading, detail = _split(text)

    if HAS_ALERT_DIALOG:
        dialog = Gtk.AlertDialog(message=heading, buttons=['Cancel', confirm_label],
                                 cancel_button=0, default_button=0)
        if detail:
            dialog.set_detail(detail)

        def chosen(source, result) -> None:
            try:
                answer = source.choose_finish(result)
            except GLib.Error:
                answer = 0          # dismissed with Escape or the window button
            on_response(answer == 1)

        dialog.choose(parent, None, chosen)
        return

    dialog = Gtk.MessageDialog(transient_for=parent, modal=parent is not None,
                               message_type=Gtk.MessageType.WARNING,
                               buttons=Gtk.ButtonsType.NONE, text=heading)
    if detail:
        dialog.props.secondary_text = detail
    dialog.add_button('Cancel', Gtk.ResponseType.CANCEL)
    accept = dialog.add_button(confirm_label, Gtk.ResponseType.ACCEPT)
    if destructive:
        accept.add_css_class('destructive-action')
    dialog.set_default_response(Gtk.ResponseType.CANCEL)
    dialog.connect('response', lambda widget, response: (
        widget.destroy(), on_response(response == Gtk.ResponseType.ACCEPT)))
    dialog.present()


def show_message_and_exit(text: str, icon: str = 'error') -> int:
    """A standalone dialog for failures that happen before the window exists."""
    application = Gtk.Application(application_id=f'{__package__}.message',
                                  flags=Gio.ApplicationFlags.NON_UNIQUE)

    def activate(app: Gtk.Application) -> None:
        app.hold()   # there is no window to keep the application alive
        show_message(text, icon, on_close=app.release)

    application.connect('activate', activate)
    application.run([])
    return 1


def open_in_file_manager(path: str) -> None:
    """Shows the item in whichever file manager is running.

    org.freedesktop.FileManager1 is implemented by Nautilus, Nemo, Dolphin and
    Thunar, and selects the item rather than just opening its folder.
    """
    uri = GLib.filename_to_uri(path, None)
    try:
        connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        connection.call_sync(
            'org.freedesktop.FileManager1', '/org/freedesktop/FileManager1',
            'org.freedesktop.FileManager1', 'ShowItems',
            GLib.Variant('(ass)', ([uri], '')), None,
            Gio.DBusCallFlags.NONE, 3000, None)
        return
    except GLib.Error:
        pass
    Gio.AppInfo.launch_default_for_uri(uri, None)
