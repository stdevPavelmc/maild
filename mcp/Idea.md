# Custom Mail MCP for MailD

This is a project to create a docker container on the network of MailD deploy (This proyect folder) containing a MCP for LLM interaction with the mailserver.

The main target is to integrate it via AI desktops asistants using the preferred way the agents use, thatś usually a MCP server, main targets are among others:

- Claude Desktop agent
- ChatGPT Desktop agent
- Gemini/Google Desktops agent
- Any LLM agent via skill describing the mcp/api usage

Use latest python3 as main language anmd base image, latest django for interface and dedicated API lib (inside or outside django) for the API mabagement.

# Structure

## Data storage

Postgres server configured via variables [host, user, password, own db] in the docker compose yml there it will preserved, habdled by the db service.

## User facing interface

Served as a own address via traefik routing like mcp.chagod.software (configurable on the docker compose yml, not hard wired in code) always with a valid SSL encription.

With several endpoints:

## Endpoints

/adminmcp - Admin management: custom user:password login with a capthcha
/ - root: Web management for users, user's page
/api/v1/ - mcp access for interactions with bearer token configured on the user endpoint.

### Admin management

Initial admin credentials are loaded from the docker compose as variables, if already set on the DB those vars passed are discarded [admin_user,_password,_email], as they are just to initialize the values on the DB

Login as admin up front, with a credentials recovery link (emails a reset password link to the admin), Use a captcha service to disallow bruteforcing on the login, use JWT tokens valid for 72h.

Once auth shows a page or multiple views [use UI/UX skills to organize it on a simple way, responsive to allow mobile device interaction with ease] with various configs organized by settings group, each settign group with his own "Update" button to save or "Restore" to reset changes made locally to server values, some of the settings group follows:

#### Admin user

- Associated email, a change on this triggers two 2FA codes sent to old and new email, user must enter the two codes [must be well signaled on the UI]
- Password change, with a 2FA confirming a code sent by email to the actual email address 

#### Domains related settings

- List of domains on the server, multiple options (can be loaded on the docker compose as a list on a var, only used if no settings are on the server, if already set this is ignored)
- Domains with MCP access allowed (tho side by side list: allowed access | denied access) doble click on one move it to the other side
- Logs actions of the user enabled|disabled [enabling this deploy next option]
- Actions to log: [log are per day rotated log on a specified folder (docker volume) access.log, audit.log, errors.log name suggested with the named actions on them]
  - Logins on web interface
  - access via auth bearer to the mcp interface
  - actions done
  - errors
  - any other action granularity needed for a security audit point of view
- Logs rotated every: [day, week, month]

#### User related settings

- Propose some settings

#### Mester tokens

- Allow to add master tokens, this tokens can access all emails and impersonate any user on any domain on the server, must be used carefully and only for the administrative users
- Each token must have a name/alias/nickname, a enabled/disabled/revoked status and a due time [default to 24h, never allow master tokens with forever time]. This interface must allow to set active/disabled/revoked (revoked ones are not deleted, just set on a diferent visual artifact [an Active|Revoked tabs?])

#### 2FA & service email sending

- service email used: read only property
- service email user internal or external service (default internal)
- if external, a server, ssl/tls, password must be declared, and a test button must be present to test the settings and credentials

### User's page

Login with a email credential, must be user@domain.tld and password, login is against configured IMAP server; Once sucessfull login for the first time that email address used is associated as the main account and default user ID

if the user has multiple emails declared on same/diferent domains [see below on settings], logging with valid creds on any of them is allowed and will lead to the user page under the main account settings (Main account is the first logged acount for that user).

Use a captcha service to disallow bruteforcing on the login, use JWT tokens valid for 24h by edfault.

This leads to a multiple view page [use UI/UX skills to organize it on a simple way, responsive to allow mobile device interaction with ease] with user settings:

#### Main account

- Must state the actual email the user used to login
- Enable / Disable MCP access master switch. The user may want temporary disable the access, this is the action.
- Multiple emails access; here we allow the user to declare other emails on the server that the user want to allow access via the MPC, each email added generates a 2fa code in a form of a magic link with a 24h valid period, a toast to the user, to find and click the link to activate this email on the MCP; emails are set but not enabled access unless the magic link is used. Maybe shown as a table with actions on the right, use a easy UI/UX paradign for this
- Set a resend magic link action on every non-confirmed email stated with a 2^n backoff time to avoid spamming starting in 1 minute.
- A disable MCP access to each address action is needed, just a "Are you sure?" reconfirmation with the email is enough, a notification email is sent to the main address of the account. Disabled accounts signs it in colkor or another UI/UX artifact
- A remove secondary address action is needed also, proceed in the same way of the disable mcp access (are you sure confirmation, and notification email)
- any other setting for the user

#### MCP access

[Note here: the proposed way is to use a auth bearer token, if there is another better/securer way, propose it]

- An option to create access tokens to the MCP interface, tokens must have a handle/nickname, like "Microsoft 365", "Copilot", "Claude Desktop", "Testing"
- Access tokens are time based, so by default a month from now, with an option to "forever" aka no due date. A toast must be raised to warn the user this token is a FOREVER one, so must keep it very secure
- a list of active tokens with actions to enable/disable/revoke them
- the due date if timed must be shown or forever id no expiry
- Yes a user may have multiple tokens for diferent services

Thus all MCP access will need a bearer token for auth purposes.

## 2FA handling

Every action that demands a 2FA confirmation via a code or magic link must be sent via a service email configured on the docker compose yml as SERVICE_EMAIL it must be an active/existen email account.

All service emails will be passed to the mta on the port 25 for delivery under no encryption and no auth as we are routing the emails on the internal docker network; a EMAIL_SENDER must be configured and the account must exist on the server 

## API interface for the MCP

### Mailbox access

We have two options, pick the one (or ones by parts) with most complete access and features [decisive points are: data integrity, fast access, access control]

Argument the options with pros an cons.

#### Direct fs access

The container will have the virtual mailbox mapped on a /home/vmail mount point via a volume, will ise uid:gid 5000:5000 to access it the structure is `domain/user` for that folder

Or 

#### doveadm master user access via the internal docker network on IMAP ports

Must have a tutorial or changes needed on the MDA contianer to expose on the internal docker network the doveadmin api and credentials if needed

### Sending emails

Sending emails is sensitive, must be done via mta as the user email address, refuse to send an email from an address not in the user primary or secondary email addresses [You must obey the user `Enable / Disable MCP access master switch` and only confirmed and enabled secondary accounts are allowed]

Device a way to send the emails under the internal docker network to the MTA, maybe via the reinjection 10025 port?

### Interactions

Here you are in charge, use options and good practives from mainstream MCP interfaces, avoid common pitfails and problems, use Python MCP SDK if possible

Compatibility with existent Email MCP protocols is a must and security is paramount.

All acccess, interactions, etc must carry a valid auth bearer token that must be associated with an user and you only can access the doman/user folders related to primary or secondary emails for that user [You must obey the user `Enable / Disable MCP access master switch` and only confirmed and enabled secondary accounts]

Actions must cover:

- Search emails for one or on all emails (does not marks as read the unread emails unless stated)
- New arrivals (from, subject, to: does not mark as read, just a hint of new emails arriving)
- Fetching emails, mark as read once fetched
- Mark read unread at user will
- Move to spam folder [needs confirmation]
- Erase email: is move to Trash, never wipe for good [needs confirmation]
- Send email as a registered account [Always put a copy on the Sent emails]
- Reply to a specific message [allways use the user recipient on that email as sender by default]
- Others options for this type of MCP, make it complete, for all options as possible on the market.
