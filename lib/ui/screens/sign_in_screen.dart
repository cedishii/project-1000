import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/log.dart';
import '../../services/cloud/account.dart';
import '../theme.dart';
import '../widgets/emblem.dart';

/// Minimum password length for new passwords.
const minPasswordLength = 8;

/// Turns a sign-in problem into a message a normal person can act on.
String authMessage(Object e) {
  if (e is AuthException) {
    final m = e.message.toLowerCase();
    final code = e.code ?? '';
    if (code == 'invalid_credentials' || m.contains('invalid login')) {
      return 'That email and password don\'t match.';
    }
    if (code == 'email_not_confirmed' || m.contains('not confirmed')) {
      return 'Please confirm your email first: open the link we emailed you.';
    }
    if (code == 'user_already_exists' || m.contains('already registered')) {
      return 'That email already has an account. Sign in instead.';
    }
    if (code.contains('rate_limit') || e.statusCode == '429') {
      return 'Too many attempts. Please wait a few minutes and try again.';
    }
    if (code == 'weak_password' || m.contains('password')) {
      return 'Please choose a longer password '
          '(at least $minPasswordLength characters).';
    }
    if (code == 'signup_disabled' || m.contains('invite-only')) {
      return 'Project: 1000 is invite-only. Ask the owner to approve your '
          'email first.';
    }
  }
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('ClientException')) {
    return 'You seem to be offline. Check your connection and try again.';
  }
  return 'Something went wrong. Please try again.';
}

enum _Mode { signIn, signUp, reset }

/// Signing in to (or creating) a Project: 1000 account.
///
/// With [membership] set the user is signed in but can't use the cloud
/// archive yet (not approved, or disabled); the screen says so.
/// [onDone] runs after signing in or out.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.membership, required this.onDone});

  final Membership? membership;
  final Future<void> Function() onDone;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _mode = _Mode.signIn;
  var _busy = false;
  var _showPassword = false;
  String? _error;
  String? _notice;

  Account get _account => Account(CloudConfig.client);

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim(), password = _password.text;
    if (!email.contains('@')) {
      setState(() => _error = 'Please enter your email address.');
      return;
    }
    if (_mode != _Mode.reset && password.isEmpty) {
      setState(() => _error = 'Please enter your password.');
      return;
    }
    if (_mode == _Mode.signUp && password.length < minPasswordLength) {
      setState(
        () => _error =
            'Please choose a password of at least $minPasswordLength '
            'characters.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      switch (_mode) {
        case _Mode.signIn:
          await _account.signIn(email, password);
          await widget.onDone();
          return;
        case _Mode.signUp:
          final signedIn = await _account.signUp(email, password);
          if (signedIn) {
            await widget.onDone();
            return;
          }
          _notice =
              'Almost there: we emailed a confirmation link to $email. '
              'Open it, then sign in here.';
          _mode = _Mode.signIn;
        case _Mode.reset:
          await _account.sendPasswordReset(email);
          _notice =
              'If $email has an account, we sent it a link to choose a new '
              'password.';
          _mode = _Mode.signIn;
      }
    } catch (e, s) {
      logError('Sign-in failed', e, s);
      _error = authMessage(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await _account.signOut();
    } catch (e, s) {
      logError('Sign-out failed', e, s);
    }
    await widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final membership = widget.membership;
    return Scaffold(
      appBar: Navigator.canPop(context) ? AppBar() : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: membership == null
                    ? _form(context)
                    : _waiting(context, membership),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _waiting(BuildContext context, Membership membership) {
    final email = _account.email ?? 'this account';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: Emblem(size: 80)),
        const SizedBox(height: 20),
        Text(
          membership is Disabled ? 'Account disabled' : 'Not approved yet',
          style: display(24),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          membership is Disabled
              ? 'The owner has disabled $email. Your list is kept safe; '
                    'ask the owner if you think this is a mistake.'
              : 'You\'re signed in as $email, but this email hasn\'t been '
                    'approved for Project: 1000 yet. Ask the owner to '
                    'approve it, then check again.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : widget.onDone,
          child: const Text('Check again'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : _signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }

  Widget _form(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (title, button) = switch (_mode) {
      _Mode.signIn => ('Sign in', 'Sign in'),
      _Mode.signUp => ('Create your account', 'Create account'),
      _Mode.reset => ('Forgot your password?', 'Send reset link'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: Emblem(size: 80)),
        const SizedBox(height: 16),
        Text('Project: 1000', style: display(28), textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        if (_mode == _Mode.signUp) ...[
          const SizedBox(height: 8),
          Text(
            'Use the email the owner approved. Your password is yours alone: '
            'nobody else, including the owner, can see your list.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 24),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          autocorrect: false,
          textInputAction: _mode == _Mode.reset
              ? TextInputAction.done
              : TextInputAction.next,
          onSubmitted: _mode == _Mode.reset ? (_) => _submit() : null,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        if (_mode != _Mode.reset) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: !_showPassword,
            autofillHints: [
              _mode == _Mode.signUp
                  ? AutofillHints.newPassword
                  : AutofillHints.password,
            ],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              helperText: _mode == _Mode.signUp
                  ? 'At least $minPasswordLength characters'
                  : null,
              suffixIcon: IconButton(
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: scheme.error),
            textAlign: TextAlign.center,
          ),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 12),
          Text(_notice!, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(button),
        ),
        const SizedBox(height: 12),
        if (_mode == _Mode.signIn) ...[
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _mode = _Mode.signUp;
                    _error = null;
                  }),
            child: const Text('New here? Create an account'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _mode = _Mode.reset;
                    _error = null;
                  }),
            child: const Text('Forgot password?'),
          ),
        ] else
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _mode = _Mode.signIn;
                    _error = null;
                  }),
            child: const Text('Back to sign in'),
          ),
      ],
    );
  }
}
