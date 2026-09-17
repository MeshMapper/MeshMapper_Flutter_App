import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_session.dart';
import 'package:mesh_mapper/widgets/repeater_admin_sheet.dart';

/// The Manage sheet used to write the typed password to the store on any
/// login, and a guest login is a login: `isLoggedIn` covers
/// [RepeaterAdminState.guest] too. With the Remember switch defaulting on
/// whenever an admin password is already stored, typing the guest password
/// once silently replaced the remembered admin one.
void main() {
  group('shouldRememberAdminPassword', () {
    test('an admin login with the switch on is stored', () {
      expect(
          shouldRememberAdminPassword(
              state: RepeaterAdminState.admin, remember: true),
          isTrue);
    });

    test('a guest login never overwrites the remembered admin password', () {
      expect(
          shouldRememberAdminPassword(
              state: RepeaterAdminState.guest, remember: true),
          isFalse);
    });

    test('the switch off stores nothing, admin or not', () {
      for (final state in RepeaterAdminState.values) {
        expect(shouldRememberAdminPassword(state: state, remember: false),
            isFalse,
            reason: '$state with the switch off must store nothing');
      }
    });

    test('no other session state is stored', () {
      for (final state in RepeaterAdminState.values) {
        if (state == RepeaterAdminState.admin) continue;
        expect(
            shouldRememberAdminPassword(state: state, remember: true), isFalse,
            reason: '$state is not a proved admin login');
      }
    });
  });
}
