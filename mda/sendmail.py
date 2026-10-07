#!/usr/bin/env python3
"""
Sendmail replacement that delivers to LMTP socket.
Drop-in replacement for /usr/sbin/sendmail with error notifications.
"""

import sys
import os
import socket
import argparse
from email.parser import BytesParser
from email.policy import compat32
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase
from email import encoders
from email.utils import formatdate, make_msgid
import logging
from pathlib import Path
from datetime import datetime

# Configuration
LMTP_SOCKET = '/var/run/dovecot/lmtp'
LOG_FILE = '/var/log/sendmail-lmtp.log'
ERROR_SUBJECT = 'Sieve - lmtp delivery error'

def _get_sysadmin_email():
    """Build SYSADMIN_EMAIL from environment variables."""
    mail_admin_user = os.environ.get('MAIL_ADMIN_USER', 'postmaster')
    default_domain = os.environ.get('DEFAULT_DOMAIN', '')
    if default_domain:
        return f'{mail_admin_user}@{default_domain}'
    return f'postmaster@localhost'

SYSADMIN_EMAIL = _get_sysadmin_email()

# Setup logging
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)

class LMTPDeliveryError(Exception):
    pass

def parse_sendmail_args():
    """Parse sendmail-compatible arguments"""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('-i', action='store_true', help='Ignore dots alone on lines')
    parser.add_argument('-t', action='store_true', help='Extract recipients from headers')
    parser.add_argument('-f', dest='sender', help='Set sender address')
    parser.add_argument('-F', dest='fullname', help='Set full name of sender')
    parser.add_argument('-o', action='append', help='Option')
    parser.add_argument('recipients', nargs='*', help='Recipient addresses')
    
    args, unknown = parser.parse_known_args()
    return args

def read_email_from_stdin():
    """Read email message from stdin"""
    try:
        return sys.stdin.buffer.read()
    except Exception as e:
        logging.error(f"Failed to read email from stdin: {e}")
        sys.exit(75)  # EX_TEMPFAIL

def extract_recipients_from_headers(email_data):
    """Extract recipients from To, Cc, Bcc headers"""
    recipients = []
    try:
        msg = BytesParser(policy=compat32).parsebytes(email_data)
        for header in ['To', 'Cc', 'Bcc']:
            if header in msg:
                addrs = msg.get_all(header, [])
                for addr in addrs:
                    from email.utils import getaddresses
                    recipients.extend([email for name, email in getaddresses([str(addr)])])
    except Exception as e:
        logging.warning(f"Failed to parse recipients from headers: {e}")
    
    return recipients

def parse_email_headers(email_data):
    """Parse email to extract key headers"""
    try:
        msg = BytesParser(policy=compat32).parsebytes(email_data)
        return {
            'subject': str(msg.get('Subject', '(no subject)')),
            'from': str(msg.get('From', '(unknown)')),
            'to': str(msg.get('To', '(unknown)')),
            'message_id': str(msg.get('Message-ID', '(none)')),
            'date': str(msg.get('Date', '(unknown)'))
        }
    except Exception as e:
        logging.warning(f"Failed to parse email headers: {e}")
        return {
            'subject': '(parse error)',
            'from': '(unknown)',
            'to': '(unknown)',
            'message_id': '(none)',
            'date': '(unknown)'
        }

def create_error_notification(original_sender, failed_recipients, error_details, original_headers, original_email_data=None):
    """Create error notification email"""
    msg = MIMEMultipart('mixed')
    msg['From'] = f'Mail Delivery System <postmaster@{socket.gethostname()}>'
    msg['To'] = SYSADMIN_EMAIL
    msg['Subject'] = ERROR_SUBJECT
    msg['Date'] = formatdate(localtime=True)
    msg['Message-ID'] = make_msgid()
    msg['Auto-Submitted'] = 'auto-replied'

    body = f"""This is an automated error notification from the mail delivery system.

DELIVERY FAILURE SUMMARY
========================
Failed to deliver message to the following recipient(s):

"""

    for recipient, error in failed_recipients.items():
        body += f"  * {recipient}\n    Error: {error}\n\n"

    body += f"""
ORIGINAL MESSAGE DETAILS
========================
From: {original_headers['from']}
To: {original_headers['to']}
Subject: {original_headers['subject']}
Date: {original_headers['date']}
Message-ID: {original_headers['message_id']}

ERROR DETAILS
=============
{error_details}

SYSTEM INFORMATION
==================
Hostname: {socket.gethostname()}
LMTP Socket: {LMTP_SOCKET}
Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}

---
This is an automatic notification. Please contact {SYSADMIN_EMAIL} if you need assistance.
"""

    msg.attach(MIMEText(body, 'plain', 'utf-8'))

    if original_email_data:
        attachment = MIMEBase('message', 'rfc822')
        attachment.set_payload(original_email_data)
        attachment.add_header('Content-Disposition', 'attachment', filename='original_message.eml')
        msg.attach(attachment)

    return msg.as_string().encode('utf-8', errors='replace')

def deliver_to_lmtp(email_data, recipients, sender=None, socket_path=LMTP_SOCKET, is_notification=False):
    """Deliver email to LMTP socket"""
    if not recipients:
        logging.error("No recipients specified")
        sys.exit(65)  # EX_DATAERR
    
    # Default sender
    if not sender:
        sender = os.environ.get('USER', 'nobody') + '@localhost'
    
    failed_recipients = {}
    error_details = []
    
    try:
        # Connect to LMTP socket
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(30)
        sock.connect(socket_path)
        
        # Read greeting
        response = sock.recv(1024).decode('utf-8', errors='replace')
        if not response.startswith('220'):
            error_msg = f"LMTP greeting failed: {response}"
            error_details.append(error_msg)
            raise LMTPDeliveryError(error_msg)
        
        # LHLO command
        sock.sendall(b'LHLO localhost\r\n')
        response = sock.recv(1024).decode('utf-8', errors='replace')
        if not response.startswith('250'):
            error_msg = f"LHLO failed: {response}"
            error_details.append(error_msg)
            raise LMTPDeliveryError(error_msg)
        
        # MAIL FROM
        sock.sendall(f'MAIL FROM:<{sender}>\r\n'.encode('utf-8'))
        response = sock.recv(1024).decode('utf-8', errors='replace')
        if not response.startswith('250'):
            error_msg = f"MAIL FROM failed: {response}"
            error_details.append(error_msg)
            raise LMTPDeliveryError(error_msg)
        
        # RCPT TO for each recipient
        accepted_recipients = []
        for recipient in recipients:
            sock.sendall(f'RCPT TO:<{recipient}>\r\n'.encode('utf-8'))
            response = sock.recv(1024).decode('utf-8', errors='replace')
            if response.startswith('250'):
                accepted_recipients.append(recipient)
            else:
                failed_recipients[recipient] = response.strip()
                error_msg = f"Recipient {recipient} rejected: {response}"
                error_details.append(error_msg)
                logging.warning(error_msg)
        
        if not accepted_recipients:
            error_msg = "All recipients rejected"
            error_details.append(error_msg)
            raise LMTPDeliveryError(error_msg)
        
        # DATA
        sock.sendall(b'DATA\r\n')
        response = sock.recv(1024).decode('utf-8', errors='replace')
        if not response.startswith('354'):
            error_msg = f"DATA failed: {response}"
            error_details.append(error_msg)
            raise LMTPDeliveryError(error_msg)
        
        # Send email data
        # Ensure CRLF line endings and dot stuffing
        lines = email_data.split(b'\n')
        for line in lines:
            line = line.rstrip(b'\r')
            if line.startswith(b'.'):
                sock.sendall(b'.' + line + b'\r\n')
            else:
                sock.sendall(line + b'\r\n')
        
        # End DATA
        sock.sendall(b'.\r\n')
        
        # Read responses for each recipient
        for recipient in accepted_recipients:
            response = sock.recv(1024).decode('utf-8', errors='replace')
            if not response.startswith('250'):
                failed_recipients[recipient] = response.strip()
                error_msg = f"Delivery to {recipient} failed: {response}"
                error_details.append(error_msg)
                logging.error(error_msg)
            else:
                logging.info(f"Delivered to {recipient}")
        
        # QUIT
        sock.sendall(b'QUIT\r\n')
        sock.close()
        
    except socket.timeout:
        error_msg = "LMTP connection timeout"
        error_details.append(error_msg)
        logging.error(error_msg)
        # Mark all recipients as failed
        for recipient in recipients:
            if recipient not in failed_recipients:
                failed_recipients[recipient] = "Connection timeout"
    except FileNotFoundError:
        error_msg = f"LMTP socket not found: {socket_path}"
        error_details.append(error_msg)
        logging.error(error_msg)
        # Mark all recipients as failed
        for recipient in recipients:
            if recipient not in failed_recipients:
                failed_recipients[recipient] = "LMTP socket not found"
    except Exception as e:
        error_msg = f"LMTP delivery failed: {e}"
        error_details.append(error_msg)
        logging.error(error_msg)
        # Mark all recipients as failed
        for recipient in recipients:
            if recipient not in failed_recipients:
                failed_recipients[recipient] = str(e)
    
    # If this is already a notification, don't create infinite loop
    if failed_recipients and not is_notification:
        # Send error notification
        try:
            original_headers = parse_email_headers(email_data)
            notification_email = create_error_notification(
                sender,
                failed_recipients,
                '\n'.join(error_details),
                original_headers,
                email_data
            )
            
            logging.info(f"Sending error notification to {SYSADMIN_EMAIL}")
            
            # Deliver notification (marked as notification to prevent loops)
            deliver_to_lmtp(
                notification_email,
                [SYSADMIN_EMAIL],
                sender=f'postmaster@{socket.gethostname()}',
                socket_path=socket_path,
                is_notification=True
            )
        except Exception as e:
            logging.error(f"Failed to send error notification: {e}")
    
    # Return appropriate exit code
    if failed_recipients:
        if len(failed_recipients) == len(recipients):
            # All failed
            sys.exit(75)  # EX_TEMPFAIL
        else:
            # Partial failure - log but exit success since some delivered
            logging.warning(f"Partial delivery failure: {len(failed_recipients)} of {len(recipients)} failed")
            # Still exit with error for partial failures
            sys.exit(75)  # EX_TEMPFAIL

def main():
    args = parse_sendmail_args()
    
    # Read email from stdin
    email_data = read_email_from_stdin()
    
    # Determine recipients
    recipients = list(args.recipients)
    if args.t:
        # Extract from headers
        header_recipients = extract_recipients_from_headers(email_data)
        recipients.extend(header_recipients)
    
    # Remove duplicates
    recipients = list(set(recipients))
    
    # Deliver
    deliver_to_lmtp(email_data, recipients, args.sender)
    
    sys.exit(0)  # EX_OK

if __name__ == '__main__':
    main()
