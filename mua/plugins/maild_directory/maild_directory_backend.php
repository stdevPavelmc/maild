<?php

/**
 * Read-only address book over the MailD catalogue (PostfixAdmin schema, PostgreSQL).
 *
 * Entries:
 *   person  every active mailbox of an active domain        → name = mailbox.name
 *   list    every active alias that is not itself a mailbox  → name = "<prefix> <local part>"
 *           (distribution lists, role addresses), when maild_directory_aliases is on;
 *           catch-alls (@domain) are never listed
 * limited to the user's own domain (scope "domain") or every hosted domain ("all"), minus the
 * hidden addresses. IDs are the address, base64url-encoded (no '@'/'.' in DOM ids).
 *
 * Every free-text search needs at least $min_chars characters; shorter terms return nothing.
 * All SQL is parameterised; LIKE metacharacters in the term are escaped.
 */
class maild_directory_backend extends rcube_addressbook
{
    public $primary_key = 'ID';
    public $readonly = true;
    public $groups = false;
    public $searchonly = false;
    public $coltypes = [
        'name' => ['limit' => 1],
        'email' => ['limit' => 1],
    ];

    /** @var ?rcube_db */
    private $db;
    private $dsn;
    private $name;
    private $scope;
    private $domain;
    private $aliases;
    private $hide;
    private $min_chars;
    private $list_prefix;

    /** @var ?array current filter: ['sql' => string, 'params' => array] */
    private $filter;
    /** @var ?rcube_result_set */
    private $result;

    public function __construct($dsn, $name, $scope, $domain, $aliases, $hide, $min_chars, $list_prefix)
    {
        $this->dsn = $dsn;
        $this->name = $name;
        $this->scope = $scope;
        $this->domain = $domain;
        $this->aliases = $aliases;
        $this->hide = array_values(array_filter($hide, 'strlen'));
        $this->min_chars = $min_chars;
        $this->list_prefix = $list_prefix;

        // scope "domain" needs to know whose domain: no user, no directory
        $this->ready = $dsn !== '' && ($scope === 'all' || $domain !== '');
    }

    #[\Override]
    public function get_name()
    {
        return $this->name;
    }

    #[\Override]
    public function set_search_set($filter): void
    {
        $this->filter = $filter;
    }

    #[\Override]
    public function get_search_set()
    {
        return $this->filter;
    }

    #[\Override]
    public function reset(): void
    {
        $this->result = null;
        $this->filter = null;
    }

    #[\Override]
    public function get_result()
    {
        return $this->result;
    }

    #[\Override]
    public function list_records($cols = null, $subset = 0, $nocount = false)
    {
        $first = max(0, ($this->list_page - 1) * $this->page_size);
        $offset = $first;
        $length = $this->page_size;
        if ($subset < 0) {
            $offset = $first + $this->page_size + $subset;
            $length = -$subset;
        } elseif ($subset > 0) {
            $length = $subset;
        }

        $this->result = new rcube_result_set(0, $first);
        if (!$this->ready || !($db = $this->db())) {
            return $this->result;
        }

        $params = [];
        $sql = $this->select_sql($params);
        $res = $db->limitquery($sql . ' ORDER BY ' . $this->order_sql(), $offset, $length, ...$params);

        while ($res && ($row = $db->fetch_assoc($res))) {
            $this->result->add($this->record($row));
        }

        if ($nocount) {
            $this->result->count = count($this->result->records);
        } else {
            $this->result->count = $this->count_rows();
        }

        return $this->result;
    }

    #[\Override]
    public function search($fields, $value, $mode = 0, $select = true, $nocount = false, $required = [])
    {
        $mode = (int) $mode & ~self::SEARCH_GROUPS;

        // direct ID lookup (used by the UI to fetch selected entries)
        if ($fields === 'ID' || $fields === $this->primary_key) {
            $ids = is_array($value) ? $value : explode(self::SEPARATOR, (string) $value);
            $emails = array_values(array_filter(array_map([$this, 'decode_id'], $ids), 'strlen'));
            $this->filter = $emails
                ? ['sql' => 'email IN (' . implode(',', array_fill(0, count($emails), '?')) . ')', 'params' => $emails]
                : ['sql' => 'FALSE', 'params' => []];
        } else {
            $this->filter = $this->text_filter($fields, $value, $mode);
        }

        if (!$select) {
            $this->result = new rcube_result_set($this->count_rows());
            return $this->result;
        }

        return $this->list_records(null, 0, $nocount);
    }

    #[\Override]
    public function count()
    {
        return new rcube_result_set($this->count_rows(), ($this->list_page - 1) * $this->page_size);
    }

    #[\Override]
    public function get_record($id, $assoc = false)
    {
        $this->search('ID', [$id], 0, true, true);
        $record = $this->result ? $this->result->first() : null;

        if ($assoc) {
            return $record ?: false;
        }

        return $this->result;
    }

    /**
     * The catalogue's display name of one active mailbox (first-login identity), or null.
     */
    public function display_name(string $email): ?string
    {
        if ($this->dsn === '' || !($db = $this->db())) {
            return null;
        }

        $res = $db->query('SELECT name FROM mailbox WHERE username = ? AND active', $email);
        $row = $res ? $db->fetch_assoc($res) : null;

        return $row ? trim((string) $row['name']) : null;
    }

    // ------------------------------------------------------------------------------ internals

    private function db(): ?rcube_db
    {
        if ($this->db === null) {
            $this->db = rcube_db::factory($this->dsn, '', false);
            $this->db->set_debug(false);
        }
        if ($this->db->is_error()) {
            $this->set_error(self::ERROR_SEARCH, 'directory database unavailable');
            return null;
        }

        return $this->db;
    }

    /**
     * The whole directory as one relation (email, name, kind), scoped and with the hidden
     * addresses removed, then the current filter on top.
     */
    private function select_sql(array &$params): string
    {
        $scope_m = $scope_a = '';
        $hide_m = $hide_a = '';
        $p_people = $p_lists = [];

        if ($this->scope === 'domain') {
            $scope_m = ' AND m.domain = ?';
            $scope_a = ' AND a.domain = ?';
            $p_people[] = $this->domain;
            $p_lists[] = $this->domain;
        }
        if ($this->hide) {
            $marks = implode(',', array_fill(0, count($this->hide), '?'));
            $hide_m = " AND lower(m.username) NOT IN ({$marks})";
            $hide_a = " AND lower(a.address) NOT IN ({$marks})";
            $p_people = array_merge($p_people, $this->hide);
            $p_lists = array_merge($p_lists, $this->hide);
        }

        $sql = 'SELECT lower(m.username) AS email, m.name AS name, \'person\' AS kind'
            . ' FROM mailbox m JOIN domain d ON d.domain = m.domain'
            . ' WHERE m.active AND d.active' . $scope_m . $hide_m;
        $params = $p_people;

        if ($this->aliases) {
            $sql .= ' UNION ALL'
                . ' SELECT lower(a.address), \'\', \'list\''
                . ' FROM alias a JOIN domain d ON d.domain = a.domain'
                . ' WHERE a.active AND d.active AND a.address NOT LIKE \'@%\''
                . ' AND NOT EXISTS (SELECT 1 FROM mailbox x WHERE x.username = a.address)'
                . $scope_a . $hide_a;
            $params = array_merge($params, $p_lists);
        }

        $sql = "SELECT email, name, kind FROM ({$sql}) dir";
        if ($this->filter) {
            $sql .= ' WHERE ' . $this->filter['sql'];
            $params = array_merge($params, $this->filter['params']);
        }

        return $sql;
    }

    private function order_sql(): string
    {
        $dir = strtoupper((string) $this->sort_order) === 'DESC' ? 'DESC' : 'ASC';
        if ($this->sort_col === 'email') {
            return "email {$dir}";
        }

        return "lower(coalesce(nullif(name, ''), email)) {$dir}, email {$dir}";
    }

    private function count_rows(): int
    {
        if (!$this->ready || !($db = $this->db())) {
            return 0;
        }

        $params = [];
        $res = $db->query('SELECT count(*) AS n FROM (' . $this->select_sql($params) . ') c', $params);
        $row = $res ? $db->fetch_assoc($res) : null;

        return $row ? (int) $row['n'] : 0;
    }

    /**
     * Free-text search → SQL over the two columns the directory has. firstname/surname/'*'
     * map to the name (and '*' to the address too); fields this book does not have are ignored.
     */
    private function text_filter($fields, $value, int $mode): array
    {
        $fields = is_array($fields) ? $fields : [$fields];
        $values = is_array($value) ? $value : array_fill(0, count($fields), $value);
        $advanced = is_array($value);

        $parts = [];
        $params = [];
        $long_enough = false;

        foreach ($fields as $i => $field) {
            $term = trim((string) ($values[$i] ?? ''));
            if ($term === '') {
                continue;
            }
            if (mb_strlen($term) >= $this->min_chars) {
                $long_enough = true;
            }

            $cols = [];
            if ($field === '*' || in_array($field, ['name', 'firstname', 'surname', 'nickname'], true)) {
                $cols[] = 'name';
            }
            if ($field === '*' || $field === 'email' || str_starts_with((string) $field, 'email:')) {
                $cols[] = 'email';
            }
            if (!$cols) {
                continue;
            }

            $or = [];
            foreach (array_unique($cols) as $col) {
                if ($mode & self::SEARCH_STRICT) {
                    $or[] = "lower({$col}) = lower(?)";
                    $params[] = $term;
                } else {
                    $like = strtr(mb_strtolower($term), ['!' => '!!', '%' => '!%', '_' => '!_']);
                    $or[] = "lower({$col}) LIKE ? ESCAPE '!'";
                    $params[] = ($mode & self::SEARCH_PREFIX) ? "{$like}%" : "%{$like}%";
                }
            }
            $parts[] = '(' . implode(' OR ', $or) . ')';
        }

        // too short (autocomplete minimum, also for the address book search box) or nothing
        // this book can match: an empty result, never the whole directory
        if (!$parts || !$long_enough) {
            return ['sql' => 'FALSE', 'params' => []];
        }

        return ['sql' => implode($advanced ? ' AND ' : ' OR ', $parts), 'params' => $params];
    }

    private function record(array $row): array
    {
        $email = (string) $row['email'];
        $name = trim((string) $row['name']);

        $local = strstr($email, '@', true) ?: $email;
        if ($row['kind'] === 'list') {
            $name = trim($this->list_prefix . ' ' . $local);
        } elseif ($name === '') {
            $name = $local;
        }

        return [
            'ID' => $this->encode_id($email),
            'name' => $name,
            'email' => [$email],
        ];
    }

    private function encode_id(string $email): string
    {
        return rtrim(strtr(base64_encode($email), '+/', '-_'), '=');
    }

    private function decode_id($id): string
    {
        $raw = base64_decode(strtr((string) $id, '-_', '+/'), true);

        return ($raw !== false && str_contains($raw, '@')) ? strtolower($raw) : '';
    }
}
