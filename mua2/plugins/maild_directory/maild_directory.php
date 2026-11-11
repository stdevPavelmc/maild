<?php

require_once __DIR__ . '/maild_directory_backend.php';

/**
 * MailD directory — the mail server's own users as a read-only Roundcube address book.
 *
 * What it does:
 *   - adds the "Directory" address book: every active mailbox of the catalogue (the PostfixAdmin
 *     schema in PostgreSQL) and, optionally, the distribution lists (aliases that are not a
 *     mailbox), limited to the user's own domain by default;
 *   - registers it for recipient autocompletion, which starts at autocomplete_min_length typed
 *     characters (3 by default) — the same minimum is enforced server-side for every free-text
 *     search of this book, so a script cannot pull the directory one letter at a time;
 *   - on a user's first login, takes their display name from the catalogue (mailbox.name) for the
 *     default identity, so the From: header is right from the first message.
 *
 * Configuration (rendered by mua2/render-config.php from the ROUNDCUBE_DIRECTORY_* variables):
 *   maild_directory_dsn      catalogue DSN (the restricted ROUNDCUBE_DB_USER role: column-level
 *                            SELECT only, it cannot read password hashes)
 *   maild_directory_scope    domain | all | off
 *   maild_directory_aliases  include distribution lists
 *   maild_directory_hide     addresses never listed (the MCP service mailbox is added by default)
 *   maild_directory_name     shown as "<name> directory" (product name)
 *
 * @license GNU GPLv3+
 */
class maild_directory extends rcube_plugin
{
    public $task = 'login|mail|addressbook|settings';

    private const ABOOK_ID = 'maild';

    #[\Override]
    public function init()
    {
        $rcmail = rcmail::get_instance();

        $this->add_texts('localization/');
        $this->add_hook('user_create', [$this, 'user_create']);

        if ($this->scope() === 'off') {
            return;
        }

        $this->add_hook('addressbooks_list', [$this, 'address_sources']);
        $this->add_hook('addressbook_get', [$this, 'get_address_book']);

        // recipients autocompletion: the personal address book first, then the directory
        $sources = (array) $rcmail->config->get('autocomplete_addressbooks', ['sql']);
        if (!in_array(self::ABOOK_ID, $sources, true)) {
            $sources[] = self::ABOOK_ID;
            $rcmail->config->set('autocomplete_addressbooks', $sources);
        }
    }

    public function address_sources($args)
    {
        $args['sources'][self::ABOOK_ID] = [
            'id' => self::ABOOK_ID,
            'name' => $this->gettext('directory'),
            'readonly' => true,
            'groups' => false,
            'autocomplete' => true,
        ];

        return $args;
    }

    public function get_address_book($args)
    {
        if ($args['id'] === self::ABOOK_ID) {
            $args['instance'] = $this->backend();
        }

        return $args;
    }

    /**
     * First login: the catalogue's display name becomes the default identity's name.
     */
    public function user_create($args)
    {
        if (!empty($args['user_name'])) {
            return $args;
        }

        $email = strtolower((string) ($args['user_email'] ?: $args['user']));
        if (!str_contains($email, '@')) {
            return $args;
        }

        $name = $this->backend()->display_name($email);
        if ($name !== null && $name !== '') {
            $args['user_name'] = $name;
        }

        return $args;
    }

    private function scope(): string
    {
        $scope = strtolower((string) rcmail::get_instance()->config->get('maild_directory_scope', 'domain'));

        return in_array($scope, ['domain', 'all', 'off'], true) ? $scope : 'domain';
    }

    private function backend(): maild_directory_backend
    {
        $rcmail = rcmail::get_instance();
        $config = $rcmail->config;

        // the logged-in user's domain (scope "domain"); empty before login (user_create)
        $domain = '';
        if (!empty($rcmail->user->ID)) {
            $domain = strtolower((string) $rcmail->user->get_username('domain'));
        }

        return new maild_directory_backend(
            (string) $config->get('maild_directory_dsn'),
            $this->gettext('directory'),
            $this->scope(),
            $domain,
            (bool) $config->get('maild_directory_aliases', true),
            array_map('strtolower', (array) $config->get('maild_directory_hide', [])),
            max(1, (int) $config->get('autocomplete_min_length', 3)),
            $this->gettext('listprefix')
        );
    }
}
