/*============================================================================
  20261124090100_legal_documents_v1.sql — the first published Terms of Use
  and Privacy Policy (version 2026-11-24).

  Applying this file is what turns the agreement on: from the moment it is
  in, everyone who opens the portal is asked to agree before anything else
  (20261124090000_legal_agreements.sql has the mechanism). Apply it AFTER
  that file, the mcp function redeploy and the portal build.

  Publishing a change
  -------------------
  Never edit a published row (a trigger refuses it, and the record of what
  people agreed to would no longer be the text they read). Add a migration
  like this one with a new version: the same insert, the new text. Everyone
  is asked to agree again the next time they open the portal, or on
  effective_at if the new row is dated ahead. The text is the portal's small
  Markdown subset (frontend/src/lib/markdown.ts): "##"/"###" headings, one
  line per paragraph and per list item, **bold**, *italic*, links.

  Idempotent: re-running inserts nothing (on conflict do nothing).

  This text is a starting point drafted for Christensen Arms. Have counsel
  review it before relying on it.
============================================================================*/

insert into public.legal_documents (doc_key, version, title, summary, body_md)
values (
  'terms',
  '2026-11-24',
  $title$Rep Portal Terms of Use and Confidentiality Agreement$title$,
  $summary$- These Terms are a binding agreement between you personally and Christensen Arms. You must accept them, and the Privacy Policy, to use the Portal, and again whenever a new version takes effect. They add to, and do not replace, your employment, rep or agency agreements, and they do not change your compensation or commissions.
- Treat everything in the Portal as Christensen Arms confidential information, including dealer, pricing, sales, order, inventory and FFL data and anything you export, screenshot or get from AI. Use it only for Christensen Arms business in your role, and never share it with competitors, the public, unapproved AI tools or any dealer other than the one it concerns. Nothing in these Terms limits disclosures the law protects, such as reporting possible violations to a government agency or, for employees, discussing pay and working conditions.
- Your account and any Claude connector token or URL are for you alone. Keep them secure, enter a connector token or URL only where the Connect Claude page tells you to, and report any loss or misuse right away.
- The Portal records your use of it. Christensen Arms administrators can review that record and can view the Portal as you, read-only, without notifying you. If you work for an agency, your agency principal can see a summary of your sign-ins and what you record on agency accounts. You have no expectation of privacy in your use of the Portal.
- Portal figures and AI output can be wrong or out of date. They are not invoices, account statements or commission statements, and nothing is an order until Christensen Arms accepts it.
- The Portal is provided as is, and Christensen Arms' liability to you for claims about the Portal or these Terms is limited to US$100 where the law allows. You must defend and cover Christensen Arms for losses caused by your breach of these Terms, your misuse of the Portal, or use of your login or Claude connection that you allow or fail to keep secure, and you give up certain claims against Christensen Arms. Subject to limited exceptions required by state law or set out in your other agreements, Utah law governs and disputes go to Utah courts without a jury, but Christensen Arms may ask any court to stop a breach of confidentiality.$summary$,
  $terms$These Rep Portal Terms of Use and Confidentiality Agreement (these **"Terms"**) are a legally binding agreement between you and Christensen Arms, together with its affiliates (**"Christensen Arms"**, **"we"**, **"us"** or **"our"**). References to Christensen Arms include the Christensen Arms entity that operates the Portal and any Christensen Arms entity that employs you or that is party to an agreement with you or with the sales representative firm you work for. These Terms govern your access to and use of the Christensen Arms Rep Portal, the private web application and installable app available at https://carms.app, including all of its features, data, content, connectors and related services (collectively, the **"Portal"**). **"You"** and **"your"** mean the individual person who signs in to the Portal and accepts these Terms.

**PLEASE READ THESE TERMS CAREFULLY. THEY CONTAIN CONFIDENTIALITY AND NON-DISCLOSURE OBLIGATIONS THAT CONTINUE AFTER YOUR ACCESS ENDS (SECTION 7), YOUR CONSENT TO MONITORING OF YOUR USE OF THE PORTAL (SECTION 10), A DISCLAIMER OF WARRANTIES (SECTION 19), A LIMITATION OF LIABILITY (SECTION 20), YOUR AGREEMENT TO DEFEND, INDEMNIFY AND HOLD HARMLESS CHRISTENSEN ARMS AND A RELEASE OF CLAIMS (SECTION 21), INJUNCTIVE RELIEF WITHOUT BOND AND RECOVERY OF ATTORNEYS' FEES (SECTION 22), AND, SUBJECT TO LIMITED EXCEPTIONS, UTAH GOVERNING LAW, AN EXCLUSIVE UTAH VENUE AND A WAIVER OF TRIAL BY JURY (SECTION 23).**

These Terms are presented together with the Rep Portal Privacy Policy and Monitoring Notice (the **"Privacy Policy"**), which you can read at any time at [carms.app/privacy](https://carms.app/privacy) and which describes the information the Portal collects, how it is used and shared, and who can see it. The Privacy Policy is incorporated into these Terms by reference. You must accept both documents to use the Portal.

## 1. Acceptance and Binding Effect

**1.1 Acceptance.** By checking the box for these Terms and selecting "Agree and continue" in the Portal, you acknowledge that you have read and understood these Terms and agree to be legally bound by them. If you do not agree, select "Decline and sign out" and do not access or use the Portal. To the extent permitted by Applicable Law, any access to or use of the Portal after these Terms have been presented to you, other than reviewing them and selecting "Decline and sign out", also constitutes your acceptance of them.

**1.2 Condition of access; consideration.** Your acceptance of, and continued compliance with, these Terms and the Privacy Policy is a condition of your access to the Portal. The Portal will ask you to accept the current version of each document before you begin using the Portal and again whenever a new version takes effect (see Section 24). You acknowledge that your access to the Portal and to the information in it is good and sufficient consideration for your obligations under these Terms.

**1.3 Supplemental instructions.** Particular features may be accompanied by additional on-screen instructions, guidelines or terms (for example, instructions for preparing orders or for connecting Claude). Those additional terms are incorporated into these Terms. If they conflict with these Terms, these Terms control unless the additional terms expressly state otherwise.

**1.4 Defined terms.** Capitalized terms have the meanings given to them in Section 4 or where they are first defined (shown in bold).

## 2. Electronic Signature and Electronic Records

**2.1 Consent to electronic transaction.** You agree that these Terms, the Privacy Policy and every later version of them may be presented, accepted, signed and retained electronically. You consent to conduct this transaction by electronic means under the Electronic Signatures in Global and National Commerce Act, 15 U.S.C. § 7001 et seq. (the **"E-SIGN Act"**), and the Uniform Electronic Transactions Act as enacted in Utah and in any other applicable state (**"UETA"**).

**2.2 Electronic signature.** Checking the box for a document and selecting "Agree and continue" is your electronic signature on that document, made with the intent to sign it, and has the same legal force and effect as your handwritten signature. These Terms are a writing signed by you for all purposes of Applicable Law, including the E-SIGN Act and UETA. You agree not to contest the validity, enforceability or admissibility of these Terms on the ground that they were presented, accepted, signed or kept in electronic form.

**2.3 Acceptance Records.** When you accept a document, the Portal records the document and version you accepted; a SHA-256 cryptographic hash of the document as published, covering its title, summary and full text (the Portal displays this hash as the document's fingerprint); the date and time of your acceptance; a snapshot of your name, email address and role at that moment; and the IP address and browser user agent reported for your request (together, an **"Acceptance Record"**). Christensen Arms administrators can view and export Acceptance Records. You agree that Acceptance Records are admissible as evidence and are presumed, unless shown otherwise, to accurately record your acceptance and the text you accepted, and that Christensen Arms may retain them, including after your access ends and after your Account is deactivated or deleted.

**2.4 Electronic communications.** You consent to receive notices, disclosures and other communications relating to the Portal and these Terms electronically, in the Portal or by email to the address associated with your Account, and you agree that they satisfy any legal requirement that a communication be in writing. To access and keep these documents you need a device with an internet connection and a current web browser capable of running the Portal. You can read the current versions at any time at [carms.app/terms](https://carms.app/terms) and [carms.app/privacy](https://carms.app/privacy), or from the account menu in the Portal, and you may print or save them for your records. You may ask for a copy of any version you accepted, including a paper copy at no charge, or withdraw your consent to electronic records, through Help & support in the Portal (the ? icon) or your Christensen Arms sales administrator. Because the Portal is offered only electronically, withdrawing your consent ends your ability to use the Portal, but it does not affect the validity of any acceptance, signature or action made before the withdrawal.

## 3. Authority; Agency Personnel

**3.1 Individual agreement.** You accept these Terms individually and in your personal capacity, whether you are an employee of Christensen Arms; an owner, employee or contractor of an independent sales representative firm or rep group that represents Christensen Arms (an **"Agency"**); a member of Christensen Arms' inside sales staff; an administrator; or any other individual to whom Christensen Arms has given access. Your obligations under these Terms are personal to you and are enforceable against you directly by Christensen Arms.

**3.2 Agency personnel.** If you use the Portal in connection with your work for an Agency, you represent and warrant that (a) the Agency has authorized you to access and use the Portal on its behalf for Christensen Arms business; (b) nothing in your arrangements with the Agency prevents you from accepting or performing these Terms; and (c) your acceptance and performance of these Terms will not breach any agreement or duty you owe to the Agency or to any other person.

**3.3 Principals.** If you own, manage or direct an Agency and the Portal identifies you as that Agency's principal (a **"Principal"**), you also agree (a) to use reasonable efforts to ensure that the Agency's personnel who have Portal access comply with these Terms; (b) to notify Christensen Arms promptly when any of them leaves the Agency, stops representing Christensen Arms or otherwise no longer needs access; and (c) to use the Agency-wide information the Portal shows you, including information about the Portal activity of the Agency's personnel, only for the Permitted Purpose.

**3.4 Agency remains bound.** Your acceptance of these Terms does not release, limit, replace or waive any obligation of your Agency to Christensen Arms under any independent sales representative agreement, rep-group or agency agreement, non-disclosure agreement or other agreement, each of which remains in full force and effect. Your Agency's obligations under its own agreements and your obligations under these Terms are cumulative.

## 4. Definitions

In these Terms, the following terms have the following meanings:

- **"Account"** means the Portal user account Christensen Arms creates for you, including its username, settings and access permissions.
- **"AI Features"** means the AI-generated account summaries, briefings, territory or company briefs and similar features offered in the Portal, as described in Section 13.1.
- **"AI Output"** means any text, summary, analysis, recommendation or other output generated, in whole or in part, from Portal information by an AI Feature or by Claude or any other artificial-intelligence system.
- **"Applicable Law"** means all federal, state, local and foreign laws, statutes, regulations, rules, ordinances, orders, judgments and other requirements of any governmental authority that apply to you, to Christensen Arms or to the relevant activity.
- **"Christensen Arms Parties"** means Christensen Arms, its affiliates, and their respective officers, directors, managers, members, employees, agents, licensors and service providers, and **"Christensen Arms Party"** means any of them.
- **"Claude"** means the AI assistant and related applications and services provided by Anthropic and its affiliates (**"Anthropic"**).
- **"Connect Claude"** means the Portal feature, where available to you, that lets you connect your Claude account to the Portal through a Model Context Protocol (MCP) connector.
- **"Connector Credentials"** means any access token, connector URL that contains a token, OAuth authorization or other credential used to connect Claude or any other application to the Portal.
- **"Content"** means notes, contacts, visit reports and surveys, photos, tasks, call outcomes and activity logs, goals, recommendation outcomes, reactions, feedback, orders, order drafts, order documents, support requests and messages, and any other information, file or material submitted to, uploaded to or created in the Portal.
- **"Credentials"** means your Account username and password, any temporary password or password-reset link, any session token, and all Connector Credentials issued to or created by or for you.
- **"Customer"** means any dealer, distributor, retailer, customer, prospective customer, ship-to location or other account whose information appears in the Portal, and its personnel.
- **"ERP Data"** means information in the Portal that is derived from Christensen Arms' enterprise resource planning, financial and other business systems, including customer, sales, invoice, order, backlog, shipment, pricing, inventory and availability information.
- **"Losses"** means all losses, liabilities, damages, judgments, awards, settlements, fines, penalties, costs and expenses, including reasonable attorneys' fees, expert fees and costs of investigation.
- **"Other Agreement"** means any employment agreement, offer letter, independent sales representative agreement, rep-group or agency agreement, non-disclosure or confidentiality agreement, employee handbook, workforce privacy notice or other written Christensen Arms policy that applies to you or to your Agency.
- **"Role"** means the role assigned to your Account (for example, sales representative, Principal, inside sales or administrator), together with the accounts, territory, data and functions Christensen Arms authorizes for that role from time to time.
- **"Your Content"** means Content submitted, uploaded or created by you or, subject to Section 5.2, through your Account or Connector Credentials, including by Claude acting through your connection.

The following terms are defined where they first appear: "Terms", "Christensen Arms", "Portal", "you" and "Privacy Policy" (the introduction); "E-SIGN Act" and "UETA" (Section 2.1); "Acceptance Record" (Section 2.3); "Agency" (Section 3.1); "Principal" (Section 3.3); "Integration Account" (Section 5.2); "Permitted Purpose" (Section 6.2); "Confidential Information", "FFL" and "Derived Materials" (Section 7.1); "Authorized Persons" (Section 7.4); "Usage Data" (Section 10.2); "your Claude account" (Section 13.3); "Feedback" (Section 16.2); and "Third-Party Services" (Section 17).

**Privacy Policy terms.** In these Terms, "Usage Data" includes the "Usage Telemetry" and other records described in the Privacy Policy; "Content" includes "User Content" as defined there; references to Connect Claude and Connector Credentials include any "Connected App" connection described there; and the "View-As" described there is the viewing described in Section 10.4. "Administrators" and "Inside Sales" in the Privacy Policy refer to the Christensen Arms administrators and inside sales staff referred to in these Terms.

## 5. Eligibility, Accounts and Credentials

**5.1 Eligibility; administrator provisioning.** The Portal is a private business system available only to persons whom Christensen Arms has authorized. Accounts are created only by Christensen Arms administrators. The Portal does not offer self-registration, and any account that a Christensen Arms administrator did not create is unauthorized and may not be used. You may use the Portal only while (a) Christensen Arms has issued you an active Account; (b) you are at least 18 years of age; and (c) you are employed or engaged by Christensen Arms, or by an Agency that currently represents Christensen Arms, in a capacity for which Christensen Arms has authorized Portal access.

**5.2 Personal and non-transferable.** Your Account and Credentials are personal to you and may not be shared, sold, transferred, lent or assigned. You may not permit any other person, including a co-worker, assistant, family member or another member of your Agency, to use your Account or Credentials, and you may not use anyone else's Account or Credentials. Each person who needs access must have their own Account. Christensen Arms may treat all activity under your Account or Credentials as your activity, except activity that Christensen Arms' records show was carried out by a Christensen Arms administrator acting under Section 10.4 (for example, after setting a new password for your Account or creating a Connector Credential for it). The restrictions on sharing in this Section 5.2, and the restrictions on direct and automated access in Section 9, do not apply to a system or integration account that Christensen Arms creates and designates in writing for automated use (an **"Integration Account"**). An Integration Account may be used only by the persons and systems, and only in the manner, that Christensen Arms authorizes in writing, and the individual who accepts these Terms for it is responsible for that use.

**5.3 Safeguarding Credentials.** You must (a) keep your password confidential, make it strong, and not reuse a password you use for any other service; (b) change any temporary password you were given, which may have been delivered to you by email, promptly after your first sign-in; (c) not write down or store your Credentials where others can find or use them; (d) never share, post, email, message or otherwise disclose any Connector Credential, including any connector URL that contains a token, to any person, enter it only into the connector settings of your Claude account or the configuration of a Claude application you use with that account (such as Claude Code), as the Connect Claude page in the Portal instructs, and treat it, and any configuration file or settings page that contains it, with the same care as your password; and (e) promptly revoke or disconnect, using the Connect Claude page in the Portal or the connected application's settings, any Connector Credential or connection that you no longer need or that may have been exposed.

**5.4 Devices and shared devices.** You are responsible for the security of every device you use to access the Portal. You must protect each device with a screen lock and passcode or equivalent protection, keep its operating system and browser up to date, and not leave the Portal open and unattended. The Portal may keep you signed in on a device until you sign out, even if you have not used it for some time. Avoid using shared or public devices; if you must use one, sign out at the end of each session and do not allow the browser to save your password.

To work quickly and offline, the Portal stores some information in the browser on your device, and the Portal does not separately encrypt it. For example, for sales representatives (including Principals, for whom this can cover the whole Agency book), recently loaded account, sales and order information, which can include credit and FFL details, may be kept on the device and used for up to 24 hours (an older copy is not used, but it can remain stored on the device until the Portal next deletes or replaces it or you sign out), and unsent visit drafts, items waiting to be sent when you are back online (which may include photos), recently opened accounts and certain preferences may also be kept there. Signing out removes the cached account information, but it does not remove unsent drafts, items waiting to be sent, certain preferences and lists, or files you have downloaded, all of which remain your responsibility under Section 7.

**5.5 Notice of compromise.** You must notify Christensen Arms immediately, through Help & support in the Portal or your Christensen Arms sales administrator, if you know or suspect that (a) any of your Credentials has been lost, stolen, disclosed or used without authorization; (b) a device used to access the Portal, or that holds Portal information or downloads, has been lost, stolen or compromised; or (c) any other security incident has affected the Portal or any Confidential Information. You must cooperate with Christensen Arms' investigation and remediation, including by changing your password and revoking Connector Credentials when asked.

**5.6 Keeping your information current.** You must promptly inform Christensen Arms of any change in your employment, engagement, Agency affiliation or Role, and of any error in your Account information.

**5.7 Christensen Arms' control of access.** Christensen Arms determines, in its sole discretion, your Role, the accounts and information you can see and the features available to you, and may change any of them at any time without notice. Some features described in these Terms are enabled only for certain users or at certain times and may not be available to you. Your ability to see or retrieve information in the Portal does not by itself authorize you to use it for any purpose other than the Permitted Purpose. If you see information that you believe you are not meant to see, you must not use, copy or disclose it, and you must notify Christensen Arms promptly.

## 6. Limited License and Permitted Purpose

**6.1 License.** Subject to your continued compliance with these Terms, Christensen Arms grants you a limited, personal, revocable, non-exclusive, non-transferable and non-sublicensable license to access and use the Portal, and the information it makes available to you, solely for the Permitted Purpose and only while your access is authorized.

**6.2 Permitted Purpose.** The **"Permitted Purpose"** means conducting the business of Christensen Arms within the scope of your Role, such as promoting and selling Christensen Arms products to the Customers you are assigned to serve, servicing those Customers, preparing and following up on orders, planning and recording calls and visits, and performing your other duties to Christensen Arms or, for Agency personnel, the Agency's duties to Christensen Arms. Any other use of the Portal or of information obtained through it is prohibited, including use for your own benefit or the benefit of any other person, or to promote or sell any other manufacturer's products or any product line other than Christensen Arms'.

**6.3 Reservation of rights.** Christensen Arms reserves all rights not expressly granted in these Terms. No license or right is granted by implication, estoppel or otherwise. The license in Section 6.1 terminates automatically when your authorization to use the Portal ends.

## 7. Confidential Information and Non-Disclosure

**7.1 Definition.** **"Confidential Information"** means all non-public information, in any form or medium, that you access, view, receive or derive through or in connection with the Portal, whether or not it is marked or identified as confidential, including:

- information about Customers, including their identities, addresses and ship-to locations, contacts and contact details, purchasing history and patterns, credit status and credit limits, payment terms, invoices, accounts receivable and other financial information, and notes about them;
- sales, revenue, bookings, backlog, order, shipment, tracking, invoice and volume information, at any level of detail, including by Customer, product, territory, representative or period;
- pricing information, including price lists and price sheets for every customer type, Customer-specific prices, discounts, programs, promotions, freight and other terms of sale;
- product, inventory, stock, availability, allocation, production and product-launch information;
- Federal Firearms License (**"FFL"**) numbers, expiration dates and other licensing information of Customers and ship-to locations;
- information about Christensen Arms' sales representatives and Agencies, including assignments, territories, books of business, goals, performance, rankings and Portal activity;
- recommendations, call lists, scores, analytics, forecasts and AI Output;
- Content created by you or by other users;
- the Portal itself, including its features, workflows, software, data structures, security measures and Credentials; and
- all notes, analyses, compilations, summaries, extracts, exports and downloads (including CSV and spreadsheet files), screenshots, photographs or recordings of screens, printouts, messages, conversations and AI Output that contain, reflect or are derived from any of the foregoing (**"Derived Materials"**).

Confidential Information includes trade secrets of Christensen Arms and confidential information of Customers and other third parties that Christensen Arms is obligated to protect. A compilation of information obtained from the Portal is Confidential Information even if some individual elements of it are publicly available.

**7.2 Exclusions.** Confidential Information does not include information that you can demonstrate by written records (a) is or becomes generally available to the public other than as a result of a disclosure by you or by anyone who received it from you; (b) was lawfully in your possession, without any obligation of confidentiality, before you received it through the Portal or otherwise from Christensen Arms; (c) is lawfully disclosed to you by a third party that is not under any obligation of confidentiality with respect to it; or (d) is independently developed by you without any use of or reference to Confidential Information. Information is not within these exclusions merely because individual parts of it are public or known to you, or because it is embraced by more general information that is public or known to you, and information about a Customer is not public merely because that Customer knows it. If you are a Christensen Arms employee, Confidential Information does not include information about your own wages, compensation, hours or working conditions. The published text of these Terms and of the Privacy Policy is not Confidential Information.

**7.3 Restriction on use.** You will use Confidential Information solely for the Permitted Purpose and for no other purpose.

**7.4 Non-disclosure.** Subject to Section 8, you will hold Confidential Information in strict confidence and will not disclose, publish, transmit, upload, share or otherwise make it available to any person other than the following (**"Authorized Persons"**): (a) Christensen Arms personnel who need it for Christensen Arms business; (b) other Portal users whom Christensen Arms has authorized to access the same information through the Portal, to the extent of that authorization; (c) a Customer, but only as to that Customer's own information (such as its own orders, shipments, invoices and backlog, and the pricing and terms Christensen Arms has made available to it), and only as reasonably necessary to serve that Customer; and (d) any other person Christensen Arms expressly approves in writing. Without limiting the foregoing, you must not disclose any Confidential Information to:

- any competitor of Christensen Arms, or any other manufacturer, brand, importer or supplier of firearms, ammunition, optics, components or accessories, or any of their sales representatives, agents or employees, even if you or your Agency also represent that manufacturer or brand;
- any Customer about any other Customer; in particular, you must never share one dealer's pricing, purchase volumes, order history, terms, credit information, contacts or other information with another dealer, and you must not share a price list or price sheet with any Customer to whom it does not apply;
- the news media, industry analysts, investors or the public, including through social media, online forums, group chats, blogs, podcasts or videos;
- any public or unapproved artificial-intelligence tool, chatbot or large language model, or any translation, transcription, note-taking, customer-relationship-management, file-sharing, cloud-storage or other third-party service, except (i) through features the Portal itself provides, such as the AI Features and Connect Claude used with your Claude account in accordance with Section 13, or (ii) through a service Christensen Arms has expressly approved in writing for that purpose; or
- any other person who is not an Authorized Person, including family members, friends, and members of your Agency who do not have their own Portal access to that information.

**7.5 Safeguards.** You will protect Confidential Information using at least the degree of care you use to protect your own most sensitive information, and in no event less than reasonable care, including by (a) complying with Section 5; (b) keeping screens that show Confidential Information out of view of unauthorized persons; (c) storing exports, downloads and other Derived Materials only on secured devices and secured business accounts under your, your Agency's or Christensen Arms' control, and not in public file-sharing services or any account that other people can access; and (d) following any additional security instructions Christensen Arms gives you.

**7.6 Minimum necessary.** You will access, download, export, copy, print, transmit and retain only the minimum Confidential Information reasonably necessary for the task at hand, and you will securely delete Derived Materials when they are no longer needed for the Permitted Purpose.

**7.7 Return and destruction.** Upon Christensen Arms' request at any time, and in any event when your authorization to use the Portal ends, you will promptly, and in any event within five business days, (a) stop using all Confidential Information; (b) return to Christensen Arms or securely destroy, as Christensen Arms directs, all Confidential Information and Derived Materials in your possession, custody or control, wherever stored, including on devices (in each browser you used to access the Portal, by clearing the Portal's stored site data, because signing out does not remove everything the Portal stores there; see Section 5.4), in email, in cloud storage, in printed form and, to the extent the service permits, in Claude or any other AI service (including conversations, projects, files and memory); (c) revoke all of your Connector Credentials and disconnect all connected applications, or, if you can no longer sign in, ask Christensen Arms to do so; and (d) upon request, certify in writing that you have done so. If Applicable Law requires you to retain any Confidential Information, you will tell Christensen Arms what you have retained and why, and these Terms will continue to apply to it for as long as you retain it. Nothing in this Section 7.7 prohibits you from retaining or providing documents or information as permitted by Section 8.

**7.8 Notice of unauthorized use or disclosure.** You will notify Christensen Arms promptly, and in any event within 24 hours, after you become aware of any actual or suspected unauthorized access to, or use or disclosure of, Confidential Information, whether by you or by anyone else, and you will cooperate fully with Christensen Arms to investigate, contain and remediate it, including by retrieving, or confirming the deletion of, any information disclosed.

**7.9 Compelled disclosure.** If you are required by law, subpoena, court order or other legal process to disclose Confidential Information, you will, to the extent legally permitted, give Christensen Arms prompt written notice so that it may seek a protective order or other remedy, cooperate with Christensen Arms in any such effort at its expense, and disclose only the portion of the Confidential Information that you are legally required to disclose. Information so disclosed remains Confidential Information for all other purposes. This Section 7.9 does not apply to any disclosure protected by Section 8.

**7.10 Personal information.** Confidential Information includes personal information about individuals, such as dealer contacts and Christensen Arms and Agency personnel. You will use personal information only for the Permitted Purpose and in compliance with Applicable Law, including Section 14.4.

**7.11 Duration.** Your obligations under this Section 7 begin when you first access the Portal or receive Confidential Information and continue during and after your access: (a) for any trade secret, indefinitely, for as long as it remains a trade secret under Applicable Law; and (b) for all other Confidential Information, for as long as it remains confidential, that is, until it falls within an exclusion in Section 7.2; provided that, if Applicable Law requires a confidentiality obligation concerning information that is not a trade secret to have a fixed duration in order to be enforceable, the obligation in this clause (b) continues for two years after your authorization to use the Portal ends or for any longer period that law permits, and clause (a) continues to apply to trade secrets.

**7.12 Ownership.** All Confidential Information is and remains the property of Christensen Arms or of the Customer or other third party to which it relates. Nothing in these Terms transfers any right in Confidential Information to you, other than the limited license in Section 6.1.

**7.13 General skills; other business.** Nothing in these Terms prevents you from using your general skills, knowledge and experience, or from doing business with any person (including a Customer) or representing any other manufacturer or product line, provided that you do not use or disclose Confidential Information in doing so and do not otherwise breach an Other Agreement. Sections 6.2 and 9 restrict only your use of the Portal and of Confidential Information, not your other lawful business activities.

## 8. Defend Trade Secrets Act Notice and Protected Rights

**8.1 Defend Trade Secrets Act notice.** Pursuant to the Defend Trade Secrets Act of 2016, 18 U.S.C. § 1833(b), you are notified that an individual shall not be held criminally or civilly liable under any federal or state trade secret law for the disclosure of a trade secret that (a) is made (i) in confidence to a federal, state or local government official, either directly or indirectly, or to an attorney, and (ii) solely for the purpose of reporting or investigating a suspected violation of law; or (b) is made in a complaint or other document filed in a lawsuit or other proceeding, if such filing is made under seal. An individual who files a lawsuit for retaliation by an employer for reporting a suspected violation of law may disclose the trade secret to the attorney of the individual and use the trade secret information in the court proceeding, if the individual files any document containing the trade secret under seal and does not disclose the trade secret, except pursuant to court order.

**8.2 Protected rights.** Nothing in these Terms or in any Other Agreement prohibits or restricts you from, or requires notice to or approval from Christensen Arms before you: (a) file a charge or complaint with, report a possible violation of law or regulation to, communicate with, provide documents or information to, or participate in any investigation or proceeding conducted by any federal, state or local governmental agency, commission or law-enforcement authority, including the Securities and Exchange Commission, the Equal Employment Opportunity Commission, the National Labor Relations Board, the Occupational Safety and Health Administration, the Department of Justice and the Bureau of Alcohol, Tobacco, Firearms and Explosives; (b) receive an award for information provided to any governmental agency; (c) testify truthfully in any legal proceeding; (d) exercise any right you have under Section 7 of the National Labor Relations Act, 29 U.S.C. § 157, if you are covered by it, or under any comparable state law, including the right to discuss or disclose your own wages, hours and other terms and conditions of employment and those of others, and to engage in other concerted activity for mutual aid or protection; (e) discuss or disclose information about unlawful acts in the workplace, such as harassment, discrimination or any other conduct that you have reason to believe is unlawful; or (f) make any other disclosure that is protected or required by law. This Section 8.2 does not permit you to disclose information protected by Christensen Arms' attorney-client privilege, except as permitted by law. Section 25.5 explains how this Section 8 relates to Other Agreements.

## 9. Acceptable Use and Prohibited Conduct

You will not, and will not attempt to or permit, encourage or assist any other person to:

- access or use the Portal, any Account, any Customer account or any information beyond the scope of your authorization or your Role, or after your authorization has ended;
- probe, scan or test the vulnerability of the Portal or any related system or network, or breach or attempt to breach any security or authentication measure, without Christensen Arms' prior written authorization;
- circumvent, disable, defeat or interfere with any access control, permission, usage limit, rate limit, agreement requirement or other technical or security measure of the Portal;
- access the Portal's databases, application programming interfaces, data services or file storage directly or by any means other than the Portal's user interface and the connectors the Portal expressly provides (such as Connect Claude), or use your session tokens or Connector Credentials outside those features, except through an Integration Account authorized under Section 5.2;
- scrape, crawl, spider, harvest, mirror or index the Portal, or download, export or extract data in bulk or systematically beyond what your Role reasonably requires for a specific business task;
- use any bot, script, macro, automated agent or other automated means to access or use the Portal, except features the Portal itself provides, uses of Connect Claude that comply with Section 13, and Integration Accounts authorized under Section 5.2;
- copy, modify, translate, adapt, create derivative works of, decompile, disassemble or reverse engineer the Portal, or attempt to derive its source code, algorithms, data models or underlying structure, except to the extent this restriction is prohibited by Applicable Law;
- upload, transmit or introduce any virus, worm, malware, ransomware, spyware or other harmful code or file;
- interfere with or disrupt the integrity, availability or performance of the Portal, or place an unreasonable load on it;
- impersonate any person, misrepresent your identity, Role or affiliation, or create, alter or falsify any record, including notes, visit reports, call outcomes, order information, Customer purchase order numbers or FFL information;
- use the Portal or any Confidential Information to compete with Christensen Arms; to solicit, divert or service any Customer or opportunity for the benefit of any other manufacturer, brand or product line; or to promote, sell or support any competing product;
- enter payment card numbers, bank account numbers, Social Security numbers or other government identification numbers, passwords, health or medical information or other sensitive personal information into notes, contacts, visit reports, order notes, support requests, file names or any other free-text field or upload, or enter any personal information that is not reasonably needed for the Permitted Purpose (free-text entries can be seen by other users and may be sent to third-party AI services, as described in Sections 10.3, 13.1, 13.3 and 15.2);
- submit any Content that is false, misleading, defamatory, harassing, threatening, discriminatory, obscene, unprofessional or otherwise unlawful, or that infringes or misappropriates any intellectual property, privacy, publicity or other right of any person;
- use Confidential Information or AI Output to train, fine-tune, evaluate or improve any artificial-intelligence or machine-learning model, other than as Christensen Arms directs;
- sell, resell, rent, lease, sublicense, frame, mirror, distribute or otherwise commercially exploit the Portal or any information in it;
- remove, obscure or alter any confidentiality, proprietary or legal notice in the Portal or in any Derived Materials; or
- use the Portal for any unlawful, fraudulent or deceptive purpose, or in violation of Applicable Law, these Terms or any Other Agreement.

## 10. Monitoring, Usage Tracking and Telemetry

**10.1 Consent to monitoring; no expectation of privacy.** The Portal is a Christensen Arms business system. To the fullest extent permitted by Applicable Law, you acknowledge and expressly consent that Christensen Arms may, at any time and without further notice (although any material expansion of the monitoring described in the Privacy Policy will be presented to you as a new version under Section 24), monitor, record, log, access, review, analyze, retain, use and disclose your use of the Portal and all Content and communications you create, submit, upload or store in it, as described in this Section 10 and in the Privacy Policy. You have no expectation of privacy in your use of the Portal, in your activity in it, or in any Content you create, submit or store in it.

**10.2 What is recorded.** As described in more detail in the Privacy Policy, the Portal records information about your use of it (**"Usage Data"**), including:

- your sign-ins, and periodic records when you open or return to the Portal (sign-ins are recorded as a security log from the moment you sign in, including before you accept these Terms);
- the screens you view, including which Customer account is on screen and which order you open, with the time and the type of device you are using (phone, tablet or desktop, based on the width of your browser window);
- the spreadsheet exports (CSV and Excel files) you download from the Portal's tables and reports, including the report name (which may include a Customer's name), the file format and the number of rows;
- certain actions and lookups (for example, looking up which dealers to contact about a product), and the notes, call and visit records, tasks, orders and other Content you create, each stored with your identity and the time;
- your use of the AI Features, including a record of each AI generation you trigger and any feedback you give on AI Output;
- Connect Claude activity, including when each connector token is created, last used and revoked, when each connected application was first and last used, and a detailed record of each order-drafting action taken through your connection (creating, updating or cancelling an order draft, or attaching a document), including the order details submitted (such as purchase order, contact, notes and email-source details, but not the contents of attached documents) and the result;
- support requests, together with technical details attached automatically (the page you were on, your browser's user agent, your browser window size, your language setting and your connection status); and
- Acceptance Records (Section 2.3).

The hosting and other service providers that operate the Portal may also keep their own technical logs, which may include IP addresses.

**10.3 Who can see it.** Christensen Arms administrators can review, report on and export Usage Data and Content, including reports that show an individual user's sign-ins, active days, screens viewed, accounts viewed, exports and recent activity. If you work for an Agency, your Agency's Principal can see summary sign-in activity for the Agency's Portal users (such as the most recent sign-in, the number of sign-ins and active days in recent periods, and counts of recorded actions and visits), and can see the Content created on the Agency's accounts, including notes, contacts, call and activity records, visit reports, photos, goals, orders and order drafts, and documents attached to orders. Christensen Arms inside sales staff can see the shared Content and the orders, including order drafts, on all accounts. Other users who have access to the same Customer account can see the notes, contacts, call and visit records, photos, goals, orders and other shared Content created on it (your tasks, support requests and feedback on AI Output, for example, are visible only to you and to Christensen Arms administrators). Christensen Arms personnel and contractors who build, operate and support the Portal, and the service providers that host it, can also access Usage Data and Content as needed for those purposes. Your Content is not private to you.

**10.4 Viewing the Portal as you.** Christensen Arms administrators may view the Portal as you, in a read-only mode, to provide support, troubleshoot, train, audit or administer the Portal. While doing so they can see the Customer accounts and information available to you, as you see them, together with items such as your tasks and AI briefs. These sessions are logged by Christensen Arms, but you are not notified of them, and activity during a read-only viewing session is not recorded as your activity. Administrators can also act on your Account directly for administrative purposes, including changing its settings and Role, setting a new password for it, deactivating it, creating or revoking Connector Credentials for it, and viewing, changing or deleting certain Content, including your tasks.

**10.5 Purposes.** Christensen Arms may use Usage Data and Content to operate, maintain, secure, support and improve the Portal; to manage sales operations, account coverage, and the engagement and performance of sales representatives and Agencies; to verify compliance with these Terms, Other Agreements, Christensen Arms policies and Applicable Law; to investigate suspected misconduct, security incidents or unauthorized disclosure; to establish, exercise or defend legal claims; to comply with legal obligations and respond to lawful requests; and for the other purposes described in the Privacy Policy.

**10.6 Privacy Policy; monitoring notice; your privacy rights.** The Privacy Policy describes these practices in more detail, and you should read it together with this Section 10. The Electronic Monitoring Notice in the Privacy Policy is Christensen Arms' notice of electronic monitoring, and your acceptance of these Terms and the Privacy Policy is your written and electronic acknowledgment of that notice. Nothing in these Terms, including Sections 10.1, 15.5, 18.3 and 21.3, waives or limits any right you have under the California Consumer Privacy Act or any other privacy or data-protection law that cannot be waived by agreement, including the rights described in the Privacy Policy, and Christensen Arms will not retaliate against you for exercising those rights.

## 11. Data Accuracy; No Reliance

**11.1 Data may lag or be incomplete.** ERP Data is copied into the Portal from Christensen Arms' business systems on a periodic schedule that varies by type of data. It may therefore lag behind, be incomplete, contain errors, or differ from Christensen Arms' official records. For example, invoicing can lag shipping, and stock and availability figures change constantly and are not a reservation, allocation or commitment to supply.

**11.2 Not an official statement.** All figures and information in the Portal, including revenue, sales, bookings, backlog, shipped value, goals, goal pace, rankings, and credit and accounts-receivable information, are provided for informational and planning purposes only. They are not invoices, official statements of account, credit decisions, or commission or compensation statements, and they are not a calculation of, or a promise to pay, any commission, bonus or other compensation. Compensation is determined solely under the applicable Other Agreement and Christensen Arms' official records, which control over any information in the Portal.

**11.3 No reliance.** You must not rely on Portal information as the sole basis for any representation to a Customer or any other person about pricing, availability, delivery dates, credit, terms or account balances, and you must verify such information with Christensen Arms before making any commitment. You are responsible for any statement you make to a Customer that Christensen Arms has not confirmed.

**11.4 Reporting errors.** If you believe any information in the Portal is inaccurate, report it through Help & support in the Portal.

## 12. Orders and Order Drafts

**12.1 Scope.** This Section 12 applies to the order features of the Portal where they are available to you.

**12.2 Your responsibility.** You are responsible for the accuracy and completeness of every order and order draft that you create, edit or submit, or that is created or edited through your Account or Connector Credentials (subject to Section 5.2), including the Customer, ship-to location, products, quantities, Customer purchase order number, requested dates, contact details, notes and attached documents. You may submit an order only if the Customer has actually requested it, and you must never invent or alter a Customer purchase order number.

**12.3 No order until accepted.** An order draft or a submitted order is only a request to Christensen Arms, and no preview, reference number or status shown in the Portal is itself an acceptance by Christensen Arms. No order, contract of sale or obligation of Christensen Arms arises unless and until Christensen Arms accepts the order, in its sole discretion, through its standard order-acceptance process, and every sale is subject to Christensen Arms' applicable terms and conditions of sale.

**12.4 Pricing.** Prices shown in the Portal, including in order drafts and previews, are derived from Christensen Arms' price lists and pricing rules and are subject to change. The price of every order is determined by Christensen Arms' applicable price lists and Christensen Arms' acceptance of the order. You have no authority to offer or agree to any price, discount, program, freight term, allocation or other term except as Christensen Arms authorizes in writing, and any price exception or override requires Christensen Arms' approval.

**12.5 FFL and legal compliance.** Firearms may be shipped only to persons and locations permitted to receive them under Applicable Law, which for shipments to dealers generally requires a valid FFL. For each order, you must confirm with the Customer that the ship-to location holds a current, valid FFL where one is required, that the FFL number and expiration date are correct, and that the products ordered may lawfully be sold and shipped to, and possessed at, the destination under federal, state and local law. FFL information displayed in the Portal comes from Christensen Arms' records, may be out of date, and does not relieve you or the Customer of these obligations; the Portal may flag an expired license, but the absence of a flag does not confirm that a license is valid. Christensen Arms may require a current copy of the FFL or other documentation before shipping. You must never knowingly submit or facilitate an order for a person who is prohibited from receiving the products, or an order that would violate Applicable Law.

**12.6 Refusal and cancellation.** Christensen Arms may, in its sole discretion and without liability, refuse, hold, cancel, modify, partially fill or delay any order or order draft for any reason, including credit, licensing, legal or regulatory compliance, allocation, availability, pricing or other errors, or suspected fraud.

**12.7 Order documents.** You may attach a document to an order only if you have the right to share it and it is needed for the order, and you must first remove any information that is not needed (such as payment card numbers). Documents and images are stored as uploaded, including any embedded metadata and their file names, and may be seen by Christensen Arms personnel and other users who can access the order.

**12.8 Orders prepared through Claude.** Where order drafting through Connect Claude is enabled for you, Claude can prepare, change or cancel order drafts and attach documents to them, but it cannot submit an order. You must review each draft prepared through Claude in the Portal and correct it before it is submitted, and submitting it is your confirmation that the order is accurate and authorized by the Customer. If you ask Claude to prepare a draft from an email, the details of that email that Claude sends (such as the sender, subject, date and an excerpt of up to 4,000 characters) are stored with the order and in Christensen Arms' audit records, and anyone who can see the order can see them. You must make sure that excerpt contains nothing that Section 9 prohibits you from entering, such as payment card numbers.

## 13. AI Features and Connect Claude

**13.1 AI Features.** Where available to you, the Portal offers AI-generated account summaries and briefings and territory or company briefs. These are produced by a third-party AI service provider engaged by Christensen Arms (currently OpenAI) from Portal information, which may include account, sales, order, backlog, goal and recommendation information and the name of the sales representative assigned to the account, as well as free-text notes, recommendation outcome notes and visit report comments written by you and by other users. Some AI Output is generated automatically (for example, on a schedule or when you first open certain screens each day), and some is generated when you request it.

**13.2 Limits of AI Output.** AI Output is generated automatically, is not reviewed by Christensen Arms before you see it, and may be inaccurate, incomplete, out of date or misleading, including by stating as fact things that are not true. You must independently verify AI Output against the underlying Portal information or Christensen Arms' records before relying on it, acting on it or sharing any part of it with a Customer. AI Output is not legal, financial, credit, compliance or other professional advice, does not state Christensen Arms' official position, and is not an offer or commitment by Christensen Arms. AI Output is Confidential Information.

**13.3 Connect Claude.** Where available to you, Connect Claude lets you connect a Claude account that you personally control, or one that Christensen Arms has provided to you for business use (in either case, **"your Claude account"**), to the Portal so that Claude can retrieve information you are authorized to see in the Portal and, if order drafting is enabled for you, prepare order drafts. By using Connect Claude, you acknowledge and agree that:

- information Claude retrieves from the Portal at your request, which may include Customer, dealer contact (including names, titles, email addresses and phone numbers), sales, pricing, order, order document, shipment, inventory, FFL and Content information (including notes, call notes and visit comments), is sent to Anthropic, and Anthropic's processing and storage of it in your Claude account are governed by the terms that apply to that account, including Anthropic's terms and policies, and not by these Terms or the Privacy Policy; Christensen Arms does not control and is not responsible for how Anthropic handles it;
- when you approve a connection, the Portal may also share with the connected application basic identity information that it requests, such as your name, email address or phone number;
- you are solely responsible for your Claude account and its security; for its settings, including data-retention, memory, sharing and model-training settings, which you must set to the most protective options available to you for business information (including opting out of the use of your conversations for model training where that option is offered); and for everything you submit to Claude or, through Claude, to the Portal;
- information obtained through Connect Claude, and the conversations and AI Output that contain it, remain Confidential Information subject to Section 7, and you must not share any Claude conversation, project or other material containing it with anyone who is not an Authorized Person;
- you will connect the Portal only to Claude, using your Claude account, and not to any other application or AI service unless Christensen Arms has approved it in writing;
- Claude cannot submit orders, cannot accept these Terms or the Privacy Policy on your behalf, and cannot bind Christensen Arms in any way, and you must not attempt to make it do so;
- you are responsible for all actions taken through your Connector Credentials, including by Claude, as if you had taken them yourself, except actions taken through a Connector Credential that a Christensen Arms administrator created for your Account and did not give to you; and
- Christensen Arms may limit, suspend or revoke Connect Claude, any Connector Credential or any tool available through it at any time, and may block Connect Claude until you have accepted the current versions of these Terms and the Privacy Policy.

**13.4 Other AI services.** Except for the AI Features and Connect Claude used in accordance with this Section 13, you must not submit Confidential Information to any artificial-intelligence service (see Section 7.4).

## 14. Compliance with Laws

You will comply with all Applicable Law in connection with your use of the Portal and your Christensen Arms business, including the following.

**14.1 Firearms laws.** You will comply with the Gun Control Act of 1968, the National Firearms Act, the regulations of the Bureau of Alcohol, Tobacco, Firearms and Explosives, and all state and local firearms laws, including those governing licensing, sales, transfers, shipping, recordkeeping and restricted firearms, magazines, components and accessories.

**14.2 Export controls and sanctions.** You will comply with the International Traffic in Arms Regulations (22 C.F.R. Parts 120 through 130), the Export Administration Regulations (15 C.F.R. Parts 730 through 774) and the economic sanctions administered by the U.S. Department of the Treasury's Office of Foreign Assets Control. You must not export, re-export, transfer or release any product, technical data, software or technology obtained through the Portal, including by disclosing it to a foreign person in the United States (a "deemed export"), without Christensen Arms' prior written authorization and any license required by law. You must not access the Portal from, or bring any device containing Portal information into, any country or region subject to comprehensive U.S. sanctions or embargoes, and you represent that you are not on, and are not owned or controlled by any person on, any U.S. government restricted-party list.

**14.3 Antitrust and competition.** You will comply with the Sherman Act and all other federal and state antitrust and competition laws. You must never use pricing, Customer, volume or other Portal information to communicate, coordinate or agree with any competitor of Christensen Arms (including another manufacturer or its representatives), or between or among dealers, about prices, margins, discounts, terms of sale, territories, customers or bids, and you must never act as a channel for exchanging competitively sensitive information between dealers. Any statement you make to a dealer about resale pricing must be consistent with Christensen Arms' written policies.

**14.4 Privacy, anti-spam and telemarketing.** When you use Portal information to contact dealer contacts or other individuals, you will comply with Applicable Law on privacy, data protection, electronic marketing, telephone calls and text messaging, including the CAN-SPAM Act, the Telephone Consumer Protection Act, the Telemarketing Sales Rule and their state counterparts. You must honor any do-not-call or do-not-email indicator shown in the Portal and any request by an individual to stop contacting them (and let Christensen Arms know about the request so its records can be updated), use contact information only for the Permitted Purpose, and not use automated dialing, prerecorded messages or mass text or email messages unless Christensen Arms has approved them.

**14.5 Anti-bribery and anti-corruption.** You will comply with the U.S. Foreign Corrupt Practices Act, federal and state commercial bribery laws, and the rules that govern dealings with government, military and law-enforcement customers. You must not offer, give, solicit or accept any payment, gift or other thing of value to obtain or retain business or any improper advantage, or to improperly influence any person, including any government official or any employee of a Customer.

## 15. Your Content

**15.1 Your responsibility.** You are solely responsible for Your Content. You represent and warrant that Your Content (a) is accurate, complete and not misleading, and that factual entries such as visit reports, call outcomes and activity logs reflect what actually occurred; (b) is professional and respectful; (c) does not include any information prohibited by Section 9; and (d) is submitted with all rights, consents and permissions required under Applicable Law and any agreement, including from individuals whose personal information or image it contains, and does not violate any obligation of confidentiality you owe to any other person.

**15.2 Your Content is not private.** Your Content may be seen and used by Christensen Arms administrators and personnel, by your Agency's Principal, and by other users who have access to the same Customer account or order, as described in Section 10.3. Your Content may also be processed by the AI Features and may be retrieved through Connect Claude by other users who are authorized to see it. Write accordingly.

**15.3 Photos and files.** Photos and other files you upload may contain embedded information (metadata), such as the location (GPS coordinates) where a photo was taken, the date and time, and details about the device. The Portal removes this information from some photos when it compresses them before upload, but not from all photos, and it does not remove it from order documents or from images attached to orders. If you do not want this information included, turn off location tagging on your camera or remove the metadata before uploading. Do not upload images of individuals without any consent required by law, or images that show another Customer's Confidential Information.

**15.4 Ownership and license.** Your Content is a business record of Christensen Arms. As between you and Christensen Arms, Christensen Arms owns Your Content to the extent it consists of information about Christensen Arms or its Customers, products, orders or business, and you hereby assign to Christensen Arms all right, title and interest you may have in that Content. To the extent you or a third party retain any right in Your Content (for example, in a document you upload), you grant, and represent that you have the authority to grant, Christensen Arms and its affiliates a perpetual, irrevocable, worldwide, royalty-free, fully paid, transferable and sublicensable license to use, reproduce, modify, adapt, publish, distribute, display, create derivative works of and otherwise exploit that Content for any lawful business purpose, and you waive, to the extent permitted by law, any moral rights in it.

**15.5 Retention, modification and deletion.** Christensen Arms may retain Your Content, including after your access ends, and may review, edit, move, reassign, restrict or delete any Content at any time, for any reason, without notice to you. Some Content, such as notes, call and visit records and visit reports, cannot be edited or deleted by you once saved, and deactivation of your Account does not delete Your Content. Other users who have access to the same Customer account can also change certain Content, including Content you created, such as dealer contacts and account goals (which they can also delete); your representations in Section 15.1 apply to Your Content as you submitted it. Christensen Arms has no obligation to monitor, store, back up or return any Content and is not responsible for any loss of Content.

## 16. Intellectual Property and Feedback

**16.1 Ownership.** The Portal and all software, code, designs, text, graphics, data, databases, compilations, analytics and AI Output in it, and all intellectual property rights in any of them, are owned by Christensen Arms or its licensors and are protected by copyright, trademark, trade secret and other laws. The Christensen Arms name and logos and related names, marks and trade dress are trademarks of Christensen Arms, and nothing in these Terms grants you any right to use them except as permitted by an Other Agreement.

**16.2 Feedback.** If you provide any suggestion, idea, comment, rating, bug report or other feedback about the Portal or Christensen Arms' business, including feedback on AI Output and feedback given through Help & support (**"Feedback"**), Christensen Arms may use and exploit it for any purpose without restriction, attribution or compensation to you, and you hereby assign to Christensen Arms all rights in it. Christensen Arms is not obligated to treat Feedback as confidential, except that any personal information in it will be handled as described in the Privacy Policy. This Section 16.2 and Section 15.4 do not apply to any invention that qualifies for protection under California Labor Code § 2870, Utah Code § 34-39-3 or any similar law, and they do not limit or replace any separate invention-assignment agreement you have with Christensen Arms.

## 17. Third-Party Services and Links

The Portal may link to, open or work with services operated by third parties, including mapping and directions services (such as Google Maps), carrier tracking websites (such as UPS), your device's phone, messaging, email and sharing features, Claude, and the AI service provider used for the AI Features (together, **"Third-Party Services"**). When you use a Third-Party Service, information is sent to it (for example, Customer addresses when you request directions or a route, a tracking number when you track a shipment, or order-status text when you share it). Information you send to a Third-Party Service that you choose to use, including Claude, is governed by that third party's terms and privacy policy. Information used for the AI Features is sent to the AI service provider by Christensen Arms, under Christensen Arms' own arrangements with that provider, as described in Section 13.1 and the Privacy Policy. Christensen Arms does not control, endorse or make any warranty about Third-Party Services and is not responsible for them or for any loss or damage arising from your use of them, which is at your own risk. You are responsible for complying with the terms of any Third-Party Service you use, and Section 7 continues to apply to any Confidential Information you send through one; for example, you may share an order's status only with Authorized Persons, such as the Customer to which the order relates.

## 18. Suspension and Termination

**18.1 By Christensen Arms.** Christensen Arms may suspend, restrict, deactivate or terminate your Account or your access to the Portal or to any feature, in whole or in part, at any time, for any reason or no reason, with or without notice, including if you breach these Terms, if your employment or engagement ends, if your Agency stops representing Christensen Arms or asks that your access be removed, or for security reasons. Christensen Arms may also modify, suspend or discontinue the Portal or any feature at any time.

**18.2 Automatic end of authorization.** Your authorization to access the Portal ends automatically, without notice, when your employment or engagement with Christensen Arms ends, when your relationship with your Agency ends, when your Agency stops representing Christensen Arms, or when your Role changes so that you no longer need access, even if your Account has not yet been deactivated. You must not access or attempt to access the Portal after your authorization has ended.

**18.3 Effect.** When your access ends for any reason, the license in Section 6.1 ends, you must immediately stop using the Portal and comply with Section 7.7, and Christensen Arms may retain your Account information, Usage Data, Acceptance Records and Content; deactivating your Account does not delete them. Christensen Arms will have no liability to you or to any third party under these Terms for any suspension or termination of your access to the Portal. This Section 18 and Section 21.3(d) concern only your access to the Portal and do not limit any right or claim you or your Agency have under an Other Agreement or Applicable Law relating to the end of your employment or engagement.

**18.4 Survival.** The following survive any termination or expiration of these Terms or of your access, together with any other provision that by its nature is intended to survive: Sections 1.3, 2, 3, 4, 5.5, 6.3, 7 and 8; Section 9, as to conduct before termination; Section 10, as to information already collected; Section 11; Section 12, as to orders and drafts created before termination; Section 13, as to information obtained through Connect Claude; Section 14, as to Confidential Information you retain or have disclosed; and Sections 15 through 27.

## 19. Disclaimer of Warranties

**TO THE FULLEST EXTENT PERMITTED BY APPLICABLE LAW, THE PORTAL AND ALL ERP DATA, CONTENT, AI OUTPUT, CONNECT CLAUDE, THIRD-PARTY SERVICES AND OTHER INFORMATION, MATERIALS AND FEATURES MADE AVAILABLE THROUGH IT ARE PROVIDED "AS IS", "AS AVAILABLE" AND "WITH ALL FAULTS", WITHOUT WARRANTY OF ANY KIND. CHRISTENSEN ARMS, FOR ITSELF AND ITS AFFILIATES, LICENSORS AND SERVICE PROVIDERS, EXPRESSLY DISCLAIMS ALL WARRANTIES, CONDITIONS AND REPRESENTATIONS, WHETHER EXPRESS, IMPLIED, STATUTORY OR OTHERWISE, INCLUDING ANY IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, NON-INFRINGEMENT, ACCURACY, COMPLETENESS, TIMELINESS, QUIET ENJOYMENT AND SYSTEM INTEGRATION, AND ANY WARRANTIES ARISING FROM COURSE OF DEALING, COURSE OF PERFORMANCE OR USAGE OF TRADE.**

**WITHOUT LIMITING THE FOREGOING, CHRISTENSEN ARMS DOES NOT WARRANT THAT THE PORTAL WILL BE AVAILABLE, UNINTERRUPTED, TIMELY, SECURE OR ERROR-FREE; THAT ANY ERP DATA, AI OUTPUT OR OTHER INFORMATION WILL BE ACCURATE, COMPLETE OR CURRENT; THAT THE PORTAL WILL WORK OFFLINE OR ON ANY PARTICULAR DEVICE OR BROWSER; THAT ANY DEFECT WILL BE CORRECTED; OR THAT ANY CONTENT, DRAFT OR QUEUED SUBMISSION WILL BE PRESERVED, DELIVERED OR NOT LOST. YOUR USE OF THE PORTAL IS AT YOUR SOLE RISK.**

**SOME JURISDICTIONS DO NOT ALLOW THE EXCLUSION OF CERTAIN WARRANTIES, SO SOME OF THE ABOVE EXCLUSIONS MAY NOT APPLY TO YOU.**

## 20. Limitation of Liability

**TO THE FULLEST EXTENT PERMITTED BY APPLICABLE LAW, IN NO EVENT WILL THE CHRISTENSEN ARMS PARTIES (CHRISTENSEN ARMS, ITS AFFILIATES, AND THEIR RESPECTIVE OFFICERS, DIRECTORS, MANAGERS, MEMBERS, EMPLOYEES, AGENTS, LICENSORS AND SERVICE PROVIDERS) BE LIABLE TO YOU OR TO ANY THIRD PARTY FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, EXEMPLARY OR PUNITIVE DAMAGES, OR FOR ANY LOSS OF PROFITS, REVENUE, SALES, BUSINESS, OPPORTUNITY, GOODWILL OR DATA, OR THE COST OF SUBSTITUTE SERVICES, ARISING OUT OF OR RELATING TO THESE TERMS, THE PORTAL, ANY ERP DATA, CONTENT OR AI OUTPUT, ANY ORDER OR ORDER DRAFT, CONNECT CLAUDE OR ANY THIRD-PARTY SERVICE, HOWEVER CAUSED AND UNDER ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY, STATUTE OR OTHERWISE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.**

**TO THE FULLEST EXTENT PERMITTED BY APPLICABLE LAW, THE TOTAL AGGREGATE LIABILITY OF THE CHRISTENSEN ARMS PARTIES FOR ALL CLAIMS ARISING OUT OF OR RELATING TO THESE TERMS OR THE PORTAL WILL NOT EXCEED ONE HUNDRED U.S. DOLLARS (US$100).**

**THE LIMITATIONS IN THIS SECTION 20 APPLY EVEN IF ANY REMEDY FAILS OF ITS ESSENTIAL PURPOSE. THEY DO NOT APPLY TO THE EXTENT APPLICABLE LAW DOES NOT PERMIT LIABILITY TO BE EXCLUDED OR LIMITED (FOR EXAMPLE, WHERE APPLICABLE LAW PROHIBITS LIMITING LIABILITY FOR FRAUD, GROSS NEGLIGENCE, WILLFUL MISCONDUCT OR VIOLATION OF LAW), IN WHICH CASE THE LIABILITY OF THE CHRISTENSEN ARMS PARTIES IS LIMITED TO THE FULLEST EXTENT PERMITTED. THIS SECTION 20 DOES NOT LIMIT (A) ANY COMPENSATION, COMMISSIONS OR OTHER AMOUNTS PAYABLE TO YOU OR YOUR AGENCY, OR ANY OTHER CLAIM ARISING, UNDER AN OTHER AGREEMENT, EACH OF WHICH IS GOVERNED SOLELY BY THAT AGREEMENT, OR (B) ANY RIGHT OR CLAIM YOU HAVE AS AN EMPLOYEE UNDER APPLICABLE LAW THAT CANNOT BE LIMITED BY AGREEMENT.**

## 21. Indemnification, Hold Harmless and Release

**21.1 Indemnification.** **SUBJECT TO SECTION 21.4 AND TO THE FULLEST EXTENT PERMITTED BY APPLICABLE LAW, YOU WILL DEFEND, INDEMNIFY AND HOLD HARMLESS THE CHRISTENSEN ARMS PARTIES (CHRISTENSEN ARMS, ITS AFFILIATES, AND THEIR RESPECTIVE OFFICERS, DIRECTORS, MANAGERS, MEMBERS, EMPLOYEES, AGENTS, LICENSORS AND SERVICE PROVIDERS) FROM AND AGAINST ANY AND ALL CLAIMS, DEMANDS, ACTIONS, SUITS, PROCEEDINGS AND INVESTIGATIONS, AND ALL RESULTING LOSSES (INCLUDING REASONABLE ATTORNEYS' FEES), ARISING OUT OF OR RELATING TO: (A) YOUR BREACH OF THESE TERMS; (B) YOUR MISUSE OF THE PORTAL OR OF ANY CONFIDENTIAL INFORMATION; (C) YOUR VIOLATION OF APPLICABLE LAW OR OF ANY RIGHT OF A THIRD PARTY, INCLUDING ANY INTELLECTUAL PROPERTY, PRIVACY OR PUBLICITY RIGHT; (D) YOUR CONTENT, INCLUDING ANY ORDER OR ORDER DRAFT AND ANY DOCUMENT YOU UPLOAD; OR (E) ANY USE OF YOUR ACCOUNT, CREDENTIALS OR CONNECTOR CREDENTIALS BY YOU, BY CLAUDE OR ANY OTHER APPLICATION YOU CONNECT, OR BY ANY OTHER PERSON TO WHOM YOU GAVE ACCESS OR WHOSE USE RESULTED FROM YOUR FAILURE TO COMPLY WITH SECTION 5, OTHER THAN USE BY CHRISTENSEN ARMS PERSONNEL OR USE RESULTING FROM A SECURITY BREACH OF THE PORTAL THAT YOU DID NOT CAUSE. YOU ARE NOT REQUIRED TO INDEMNIFY A CHRISTENSEN ARMS PARTY FOR LOSSES TO THE EXTENT THEY ARE CAUSED BY THAT CHRISTENSEN ARMS PARTY'S NEGLIGENCE, GROSS NEGLIGENCE, WILLFUL MISCONDUCT OR VIOLATION OF LAW.**

**21.2 Control of defense.** Christensen Arms has the right, at its option, to assume the exclusive defense and control of any matter for which you are required to indemnify a Christensen Arms Party, with counsel of its choosing, and you will reimburse its reasonable costs of doing so and cooperate fully in the defense. If Christensen Arms does not assume the defense, you will defend the matter with counsel reasonably acceptable to Christensen Arms. You will not settle any matter in a way that imposes any obligation or admission on any Christensen Arms Party without Christensen Arms' prior written consent.

**21.3 Release.** **SUBJECT TO SECTION 21.4 AND TO THE FULLEST EXTENT PERMITTED BY APPLICABLE LAW, YOU RELEASE AND FOREVER DISCHARGE THE CHRISTENSEN ARMS PARTIES FROM, AND WAIVE, ALL CLAIMS, DEMANDS AND LOSSES, KNOWN OR UNKNOWN, ARISING OUT OF OR RELATING TO (A) THE ACCURACY, COMPLETENESS, AVAILABILITY OR TIMELINESS OF THE PORTAL, ERP DATA OR AI OUTPUT; (B) ANY THIRD-PARTY SERVICE, INCLUDING CLAUDE AND THE AI SERVICE PROVIDER USED FOR THE AI FEATURES; (C) THE MONITORING, RECORDING AND OTHER PRACTICES DESCRIBED IN SECTION 10 AND IN THE PRIVACY POLICY, TO WHICH YOU HAVE CONSENTED, TO THE EXTENT THEY ARE CARRIED OUT AS DESCRIBED THERE; AND (D) ANY SUSPENSION OR TERMINATION OF YOUR ACCESS TO THE PORTAL. YOU EXPRESSLY WAIVE THE BENEFIT OF ANY STATUTE OR RULE OF LAW, SUCH AS CALIFORNIA CIVIL CODE § 1542, THAT WOULD OTHERWISE LIMIT THIS RELEASE TO CLAIMS YOU KNOW OR SUSPECT TO EXIST AT THE TIME YOU ACCEPT THESE TERMS.**

**21.4 Limits.** Nothing in this Section 21 (a) releases, or requires indemnification for, any claim that cannot be released or indemnified as a matter of law; (b) releases any claim arising from a Christensen Arms Party's fraud, gross negligence, willful misconduct or violation of Applicable Law; (c) releases any claim for compensation, commissions or other amounts under an Other Agreement, or any other claim arising under an Other Agreement; (d) if you are an employee of Christensen Arms, requires you to indemnify Christensen Arms for Losses arising from your good-faith performance of your job duties in accordance with Christensen Arms' instructions, or limits any right to indemnification or reimbursement you have under Applicable Law or Christensen Arms policy; or (e) waives or limits any right described in Section 8 or Section 10.6.

## 22. Equitable Relief and Enforcement

**22.1 Injunctive relief.** You acknowledge that Confidential Information is unique and valuable, and that any actual or threatened breach of Sections 5, 6, 7, 9 or 13 would cause Christensen Arms irreparable harm for which monetary damages would be an inadequate remedy. Accordingly, in addition to all other remedies available at law or in equity, Christensen Arms is entitled to temporary, preliminary and permanent injunctive relief, specific performance and other equitable relief to prevent or restrain any such breach, without the necessity of proving actual damages and, to the fullest extent permitted by law, without posting a bond or other security. Christensen Arms may seek such relief in any court of competent jurisdiction, notwithstanding Section 23.2.

**22.2 Attorneys' fees.** In any action or proceeding to enforce Section 7 or otherwise to protect Confidential Information, the prevailing party is entitled to recover its reasonable attorneys' fees, costs and expenses, in addition to any other relief awarded.

**22.3 Other remedies.** Unauthorized access to or use of the Portal or of Confidential Information may also violate the Computer Fraud and Abuse Act (18 U.S.C. § 1030), the Defend Trade Secrets Act, the Utah Uniform Trade Secrets Act and other laws, and Christensen Arms may pursue all available civil and criminal remedies. Christensen Arms' rights and remedies under these Terms are cumulative and in addition to those available under any Other Agreement or Applicable Law.

## 23. Governing Law; Venue; Jury Trial Waiver

**23.1 Governing law.** Subject to Sections 23.4 and 23.5, these Terms, and any dispute, claim or controversy arising out of or relating to these Terms, the Portal or your use of it, whether in contract, tort, statute or otherwise, are governed by the laws of the State of Utah, without regard to its conflict-of-laws rules, and, where applicable, the federal laws of the United States.

**23.2 Exclusive venue.** Subject to Sections 22.1, 23.4 and 23.5, any action or proceeding arising out of or relating to these Terms, the Portal or your use of it must be brought exclusively in the state or federal courts located in the State of Utah. You and Christensen Arms each irrevocably consent to the personal jurisdiction of, and venue in, those courts, and waive any objection based on inconvenient forum or improper venue.

**23.3 Jury trial waiver.** **TO THE FULLEST EXTENT PERMITTED BY LAW, AND SUBJECT TO SECTION 23.4, YOU AND CHRISTENSEN ARMS EACH KNOWINGLY, VOLUNTARILY AND INTENTIONALLY WAIVE ANY RIGHT TO A TRIAL BY JURY IN ANY ACTION OR PROCEEDING ARISING OUT OF OR RELATING TO THESE TERMS, THE PORTAL OR YOUR USE OF IT.**

**23.4 State-law exceptions.** If you are a Christensen Arms employee who primarily resides and works in California, Sections 23.1 and 23.2 do not require you to adjudicate outside California a claim arising in California, or deprive you of the substantive protection of California law with respect to a controversy arising in California. The same applies, with respect to that state, if you primarily reside and work in another state whose law prohibits an employer from requiring an out-of-state choice of law or forum as a condition of employment. Section 23.3 does not apply to any claim for which a pre-dispute waiver of trial by jury is unenforceable under the law governing that claim.

**23.5 Other dispute-resolution agreements.** If you or your Agency are party to an Other Agreement that contains an arbitration agreement or a governing-law, venue or other dispute-resolution provision, that provision governs every dispute within its scope, including a dispute arising out of or relating to these Terms or the Portal if it falls within that scope, and this Section 23 applies only to disputes outside its scope. This Section 23 does not apply to any claim for commissions or other compensation, which remains governed by the applicable Other Agreement and Applicable Law. Seeking injunctive or other interim relief from a court under Section 22.1 does not waive any right to arbitrate under such an agreement.

## 24. Changes to These Terms

Christensen Arms may amend these Terms or the Privacy Policy at any time. Each new version will be published in the Portal with its own version number and effective date, which the Portal displays with the document. When a new version takes effect, the Portal will ask you to read and accept it before you can continue using the Portal, and your continued use of the Portal requires your acceptance. If you do not accept a new version, you must stop using the Portal, and you may select "Decline and sign out". Each version governs your use of the Portal from the time you accept it; your obligations under earlier versions with respect to Confidential Information you received while they were in effect continue; and a change does not apply to a dispute that arose before you accepted it unless you and Christensen Arms agree otherwise. Christensen Arms may also add, change or remove features of the Portal without changing these Terms.

## 25. Relationship to Other Agreements

**25.1 Supplement, not replacement.** Except as provided in Sections 8 and 25.5, these Terms supplement, and do not replace, supersede, amend or limit, any Other Agreement. Your obligations under these Terms are in addition to your obligations, and your Agency's obligations, under any Other Agreement.

**25.2 Conflicts.** Subject always to Sections 8 and 25.5, if a provision of these Terms conflicts with a provision of an Other Agreement concerning confidentiality, non-disclosure, data protection, data security, or the use, return or destruction of information, the provision that gives greater protection to Christensen Arms and its information will control, to the extent of the conflict. In all other respects, if a signed Other Agreement directly conflicts with these Terms, the Other Agreement controls to the extent of the conflict, except that these Terms control on matters specific to the Portal, such as Accounts and Credentials, acceptable use of the Portal, monitoring, Connect Claude and the AI Features. Dispute resolution is addressed in Section 23.5.

**25.3 Compensation unaffected.** These Terms do not change your compensation or commissions, or your Agency's, or any commission rate, territory, payment term or other economic term of any Other Agreement. The accounts, territory and figures shown to you in the Portal are access and reporting settings only, and they do not grant, define or modify any territory, account assignment, exclusivity or entitlement to any commission or other compensation.

**25.4 No employment or agency relationship.** Nothing in these Terms, and no access to or use of the Portal, creates any employment, agency, partnership, joint venture, franchise or fiduciary relationship between you (or your Agency) and Christensen Arms that does not otherwise exist, or changes the nature of any existing relationship. If you are not a Christensen Arms employee, your access to the Portal does not make you one. You have no authority to bind Christensen Arms, to accept orders on its behalf, or to make any representation, warranty or commitment on its behalf, except as expressly authorized in an Other Agreement or otherwise in writing by Christensen Arms. The requirements in these Terms relate solely to the security and permitted use of the Portal and of Christensen Arms' information, and to compliance with Applicable Law. They are not intended to, and do not, control the manner, means, hours, location or methods by which you or your Agency perform services, which remain governed by the applicable Other Agreement.

**25.5 Protected rights control.** Section 8 applies notwithstanding Sections 25.1 and 25.2, Section 26.7 and any provision of any Other Agreement. Christensen Arms will not interpret or enforce any Other Agreement to prohibit, restrict or require notice of any conduct described in Section 8, and to the extent any Other Agreement could be read to do so, it is modified to that extent as between you and Christensen Arms.

## 26. General Provisions

**26.1 Severability.** If any provision of these Terms is held invalid, illegal or unenforceable in any respect, that provision will be enforced to the maximum extent permissible and modified to the minimum extent necessary to make it enforceable (and a court may so modify it), and the remaining provisions will remain in full force and effect.

**26.2 No waiver.** No failure or delay by Christensen Arms in exercising any right or remedy operates as a waiver of it, and no waiver is effective unless it is in writing and issued by an authorized representative of Christensen Arms. A waiver on one occasion is not a waiver on any other occasion.

**26.3 Assignment.** You may not assign, delegate or transfer these Terms or any of your rights or obligations under them, by operation of law or otherwise, and any attempt to do so is void. Christensen Arms may assign or transfer these Terms, in whole or in part, without your consent, including to an affiliate or to a successor in connection with a merger, acquisition, reorganization or sale of assets. These Terms bind and benefit the parties and their permitted successors and assigns.

**26.4 Notices.** Christensen Arms may give you notices under these Terms by posting them in the Portal (including on the screen you see when you sign in) or by email to the address associated with your Account, and such notices are effective when posted or sent. You may give notices to Christensen Arms as described in Section 27, unless Christensen Arms designates another method in writing.

**26.5 Survival.** The provisions identified in Section 18.4 survive as stated there.

**26.6 Interpretation; headings.** In these Terms, "including" and similar words mean "including without limitation"; "or" is not exclusive; words in the singular include the plural and vice versa; and a reference to a Section is to a section of these Terms unless the reference identifies another law or document. Headings are for convenience only and do not affect interpretation. These Terms will not be construed against either party as the drafter. Any summary displayed with these Terms is for convenience only, is not part of these Terms and does not limit or change them; this full text controls.

**26.7 Entire agreement.** These Terms, together with the Privacy Policy and any supplemental terms described in Section 1.3, are the entire agreement between you and Christensen Arms concerning the Portal and supersede all prior and contemporaneous understandings concerning the Portal, subject always to Section 23.5 and to Section 25, under which Other Agreements remain in effect. If these Terms and the Privacy Policy conflict, the Privacy Policy controls as to the description of the information the Portal collects, how it is used, shared and retained, and your privacy rights, and these Terms control as to all other matters.

**26.8 Force majeure.** Christensen Arms is not liable for any delay or failure to perform caused by events beyond its reasonable control, including failures of the internet, of hosting or other service providers, of business systems or of utilities.

**26.9 Third-party beneficiaries.** The Christensen Arms Parties are intended third-party beneficiaries of Sections 19, 20 and 21. Otherwise, these Terms do not confer any right or remedy on any third party.

**26.10 Language.** These Terms are written in English. Any translation is provided for convenience only, and the English version controls in the event of any inconsistency.

## 27. Contact

If you have questions about these Terms, or need to give Christensen Arms a notice under them (including notice of a security incident or an unauthorized disclosure), contact Christensen Arms through Help & support in the Portal (the ? icon) or through your Christensen Arms sales administrator.$terms$
)
on conflict (doc_key, version) do nothing;

insert into public.legal_documents (doc_key, version, title, summary, body_md)
values (
  'privacy',
  '2026-11-24',
  $title$Rep Portal Privacy Policy and Monitoring Notice$title$,
  $summary$- This Policy explains what the Christensen Arms Rep Portal collects about you, how it is used and who can see it. It covers only Portal users.
- We record your sign-ins and how you use the Portal (screens and accounts you view, downloads, and "Who should I call?" lookups). We use this for security, support, coaching and measuring performance (for Agency reps, as it relates to account coverage and the Agency's performance). If you work with an Agency, your Agency's Principal can see when and how often you sign in. You cannot opt out of this monitoring while you use the Portal.
- What you write on an account (notes, contacts, visits, photos, orders and more) is not private. Administrators, Inside Sales and anyone else whose Book includes that account, including your Agency's Principal for Agency accounts, can see it. Administrators can also view the Portal as you, read-only, and you are not notified when they do.
- Account information, including notes and visit comments, is sent to OpenAI to produce AI summaries and daily briefs, some of them automatically. If you, or another user who has the same account, connect Claude, Anthropic receives what Claude asks for under that user's own Anthropic account, and this can include what you wrote on the account. We do not sell your information or use third-party advertising or analytics trackers.
- Some data stays on your device, including drafts and unsent visits, and signing out does not remove them. We keep Portal records as long as we need them for business, legal and audit purposes. For questions or requests, use Help & support (the ? icon) or contact your Christensen Arms sales administrator.$summary$,
  $privacy$## 1. Scope, Definitions and Relationship to Other Agreements

This Rep Portal Privacy Policy and Monitoring Notice (this **"Policy"**) describes how Christensen Arms, together with its affiliates (**"Christensen Arms"**, **"we"**, **"us"** and **"our"**), collects, uses, discloses, retains and protects information, including Personal Information (as defined in Section 1.4), in connection with the Christensen Arms Rep Portal. The Rep Portal is the private web application and installable progressive web app made available at https://carms.app, together with its related services, programming interfaces and connectors (collectively, the **"Portal"**). This Policy is a companion to, and is incorporated by reference into, the Rep Portal Terms of Use and Confidentiality Agreement (the **"Terms"**), which you can read at any time at [carms.app/terms](https://carms.app/terms). This Policy is available at any time at [carms.app/privacy](https://carms.app/privacy).

### 1.1 Who This Policy Covers

This Policy applies only to individuals to whom Christensen Arms has issued a Portal account (each, a **"User"** or **"you"**). Users include: (a) Christensen Arms employees who act as sales representatives; (b) independent sales representatives, and the owners, employees and other personnel of independent rep-group agencies that represent Christensen Arms (each, an **"Agency"**), including any individual who runs an Agency and is designated in the Portal as its principal (a **"Principal"**); (c) inside sales and order-entry personnel (**"Inside Sales"**); and (d) Christensen Arms personnel who administer the Portal (**"Administrators"**). Only Administrators create Portal accounts. There is no public or self-service registration.

### 1.2 What This Policy Does Not Cover

This Policy does not apply to christensenarms.com or to any other Christensen Arms website, online store, product, consumer service or social-media page, each of which is governed by its own notices. It also does not apply to information Christensen Arms collects outside the Portal (for example, human-resources, payroll or benefits records), which is governed by the applicable Other Agreements (Section 1.5) and notices. It does not govern how your Agency, or any third party that a User chooses to use (such as Anthropic, when a User connects Claude), handles information outside the Portal.

### 1.3 Business and Workforce Context

The Portal is a business tool provided solely for selling and supporting Christensen Arms products. We collect and process the information described in this Policy in a business-to-business and workforce context, in connection with your employment by Christensen Arms or your (or your Agency's) commercial relationship with Christensen Arms.

### 1.4 Defined Terms

**"Personal Information"** means information that identifies, relates to, describes, is reasonably capable of being associated with, or could reasonably be linked, directly or indirectly, with a particular individual. Your **"Book"** is the set of dealer and customer accounts you are permitted to access in the Portal. It is determined by your role, your sales representative code, your Agency and any access grants or revocations made by an Administrator. Administrators and Inside Sales have access to every account. **"ERP"** means Christensen Arms' enterprise resource planning system, from which most business data in the Portal is loaded.

The terms "User Content", "Usage Telemetry", "Connected App" and "View-As" have the meanings given in Sections 3.5, 3.3, 3.6 and 3.8, respectively. Capitalized terms used but not defined in this Policy have the meanings given in the Terms. For consistency with the Terms: User Content corresponds to what the Terms call "Your Content"; Usage Telemetry is part of what the Terms call "Usage Data"; an agreement record (Section 3.4) is an "Acceptance Record"; and the tokens, connector addresses and approvals used to connect a Connected App are "Connector Credentials".

### 1.5 Relationship to Other Agreements

This Policy supplements, and does not replace or supersede, any Other Agreement that applies to you. **"Other Agreement"** has the meaning given in the Terms and includes any employment agreement, offer letter, independent sales representative agreement, rep-group or Agency agreement, nondisclosure or confidentiality agreement, employee handbook, workforce privacy notice and other written Christensen Arms policy that applies to you or to your Agency. If this Policy conflicts with an Other Agreement regarding confidentiality or data protection, the provision that is more protective of Christensen Arms' information will control. Nothing in this Policy changes your compensation or commissions, or your Agency's. Nothing in it creates any employment, agency, partnership or joint-venture relationship between you (or your Agency) and Christensen Arms that does not otherwise exist, or confers any right to continued access to the Portal.

### 1.6 Survival, Severability and Rights Under Law

This Policy continues to apply to information collected through the Portal after your access ends, your account is deactivated or this Policy is replaced, for as long as that information is retained. If any provision of this Policy is held invalid or unenforceable, it will be enforced to the maximum extent permissible, and the remaining provisions will remain in full force and effect. Nothing in this Policy, including Sections 1.5, 2 and 10, waives or limits any right you have, or any obligation Christensen Arms has, under applicable law that cannot be waived or limited by agreement, including under the CCPA (Section 12).

## 2. Electronic Monitoring Notice

**CHRISTENSEN ARMS MONITORS, RECORDS AND REVIEWS USE OF THE PORTAL. PLEASE READ THIS SECTION CAREFULLY.**

The Portal is a business system owned or controlled by Christensen Arms, and the business information in it is confidential information of Christensen Arms, as described in the Terms. By accessing or using the Portal, you acknowledge and consent to Christensen Arms monitoring, recording, logging, reviewing, analyzing, retaining and (as described in this Policy) disclosing: (a) your sign-ins to and use of the Portal, as described in Sections 3.2 and 3.3; (b) all User Content and other information you submit to, store in or transmit through the Portal, including through a Connected App; and (c) the other records described in Section 3. Monitoring is conducted by electronic means and applies to every User, including Administrators and Inside Sales. Administrators may review its results at any time and may also view the Portal as you (Section 7.1).

**TO THE FULLEST EXTENT PERMITTED BY LAW, YOU HAVE NO EXPECTATION OF PRIVACY, AS AGAINST CHRISTENSEN ARMS AND THE PERSONS DESCRIBED IN SECTION 7, IN YOUR USE OF THE PORTAL OR IN ANY INFORMATION YOU SUBMIT TO, STORE IN OR TRANSMIT THROUGH IT. MONITORING IS A CONDITION OF ACCESS, AND YOU CANNOT OPT OUT OF IT WHILE YOU USE THE PORTAL.**

Christensen Arms uses the results of monitoring for the purposes described in Section 6, including security, audit, investigations, support, and measuring adoption and performance, which includes coaching and performance management as Section 6 describes. The monitoring the Portal performs is limited to the activities described in Section 3; in particular, the Portal does not record keystrokes, capture your screen or track the location of your device (Section 3.3). If Christensen Arms materially expands the monitoring described in this Policy, it will publish a new version of this Policy for your agreement (Section 16).

This Section is intended to serve as notice of electronic monitoring to the extent applicable law requires or permits such notice, including under state laws that require employers to notify employees of electronic monitoring. It supplements, and does not replace, any separate electronic-monitoring notice that Christensen Arms gives, posts or asks you to acknowledge under applicable law. Your acceptance of this Policy in the Portal constitutes your written and electronic acknowledgment of this notice. If an Agency, rather than Christensen Arms, is your employer, this Section describes only Christensen Arms' monitoring of its own system and does not describe any monitoring your Agency may conduct.

Nothing in this Policy, including this Section and any statement that information in the Portal is confidential, limits the rights described in Section 8 of the Terms (Defend Trade Secrets Act Notice and Protected Rights), including any right you have under Section 7 of the National Labor Relations Act or to report possible violations of law to a government agency.

## 3. Information We Collect

We collect the categories of information described below. Some categories apply only to particular roles. Christensen Arms enables some features selectively, and they may not be available to you; this Policy describes those features as available "where enabled" or "if available to you."

### 3.1 Account and Profile Information

When an Administrator creates or maintains your account, we collect and store: your full name; your email address, which is your sign-in identifier; your role (Administrator, sales representative or Inside Sales); your ERP sales representative code, if any; the Agency (ERP vendor) for which you are designated as Principal, if any; whether your account is active; and the date your account was created. Our authentication provider maintains your sign-in credentials and related data. These include your password (stored in hashed form), your sign-in sessions, any suspension of your account and any approvals you give to Connected Apps. Our authentication provider may also record, in its own records and logs, the IP address and browser user-agent string associated with your sign-ins, sessions, password resets and other authentication events.

We also keep administrative records about your account. These show which accounts an Administrator has specifically added to or removed from your Book, and which Administrator did so. If order drafting through a Connected App is enabled for you, they also show which Administrator enabled it, when, and any note recorded with it.

### 3.2 Authentication and Sign-In Records

The Portal creates a sign-in record containing only your user identifier and the date and time (Section 3.1 describes the separate records our authentication provider keeps). A sign-in record is created: (a) each time you successfully sign in with your password, including before you have agreed to this Policy and the Terms; and (b) when you open the Portal with a saved session, or return to it after it has been in the background. Records under clause (b) are created no more than once every four hours in each browser on each device, and only while the device is online, the Portal is visible on screen and you have agreed to the current versions of this Policy and the Terms. The four-hour interval is tracked by a timestamp stored on your device (Section 4). An Administrator's View-As session (Section 3.8) creates no sign-in record. Your own use of the Portal on your own devices is recorded as usual, even while an Administrator is viewing the Portal as you.

Sign-in records are used for security and audit. They are also used to calculate activity measures, such as your most recent sign-in, how many times you signed in and on how many days, which are visible to the persons described in Section 7. If you request a password reset, our authentication provider sends a single-use link to your email address.

### 3.3 Usage Telemetry and Monitoring

After you have agreed to the current versions of this Policy and the Terms, the Portal records the events listed below (**"Usage Telemetry"**). Our servers stamp each event with your user identifier and the date and time.

- **Page views:** the name of the Portal screen you open (for example, an account screen or an order screen, not the full web address), the dealer or customer account displayed on that screen, if any, and, on order screens, the order identifier. A page view is recorded when you move to a different screen and for the first screen you see after you sign in or agree. It is recorded again for the same screen when you return to the Portal (for example, by switching back to its tab) and at least 30 minutes have passed since that screen was last recorded.
- **Downloads:** when you export data to a file, the name of the report, the file format (CSV or XLSX) and the number of rows, together with the screen and account you were viewing. Report names frequently include a dealer or account name.
- **"Who should I call?" lookups:** when you use that action, the identifier of the product you looked up, together with the screen and account you were viewing.
- **Device class:** for each event, whether you were using a phone, tablet or desktop. This is determined solely from the width of your browser window, not from your browser identity or any device identifier.

Usage Telemetry is held briefly in your browser's memory and sent to our servers in small batches. It is not saved to your device. Events that occur while your device is offline are discarded rather than stored and sent later. Usage Telemetry is recorded for every role, including Administrators and Inside Sales. Within the Portal, only Administrators can view Usage Telemetry (Section 7.1). You cannot view your own Usage Telemetry in the Portal, but you may request a copy (Section 11).

**What is not collected.** The Portal does not record:

- your keystrokes;
- the text you type into a search box or into other fields, other than User Content you choose to save or send (but see "Search terms" below);
- your clicks, taps, scrolling or cursor movements, other than the events listed above;
- screen recordings or screenshots;
- the precise location of your device (see Section 3.5 regarding location data embedded in photos); or
- the contacts, photos or files stored on your device, other than files you choose to upload.

**Search terms.** Text you type into a search box is sent to our servers to run the search, so it may appear in our hosting providers' request logs (Section 3.10). On some screens, such as order lookup, the search term also appears in the screen's web address, so it is included in any help request you send from that screen (Section 3.5). The Portal does not otherwise store search terms in its own records, and it does not add them to Usage Telemetry.

The Portal does not use your device's location services, microphone, notifications or push messaging. It reaches your camera only through your device's own file picker, when you choose to take a photo. The Portal reads certain device signals locally, such as network status, whether the Portal is visible on screen and your browser type (used to format text-message links). Apart from the device class described above, the Portal itself sends such signals to us only with a help request, which includes your browser's user-agent string, window size, language and online status (Section 3.5). Separately, your browser sends its user-agent string with every request it makes, which our hosting providers may log (Section 3.10) and which is stored with your agreement records (Section 3.4).

**When nothing is recorded.** Usage Telemetry is not recorded while you are signed out; on the sign-in, password-reset and agreement screens or the public Terms of Use and Privacy Policy pages; or while your device is offline. Nothing an Administrator does while viewing the Portal as you (Section 7.1) is recorded as Usage Telemetry or as a sign-in record, either for the Administrator or for you. View-As does not pause the recording of your own use: if you use the Portal on your own device at the same time, that use is recorded as usual.

Until you have agreed to the current versions of this Policy and the Terms, the Portal application stores on our systems only the following records of your activity:

- the sign-in record described in Section 3.2(a);
- the session records our authentication provider creates and maintains when you sign in (Section 3.1);
- if a Connected App is already connected to your account, the records of that connection, including the "last used" times described in Section 3.6, which are updated whenever that app contacts the Portal even though the Portal refuses its tool requests until you agree; and
- when you agree, the agreement records described in Section 3.4.

The automatic request logs kept by our hosting providers (Section 3.10) operate independently of these controls.

### 3.4 Agreement Records

When you agree to this Policy and the Terms, we record, for each document:

- the document and version you agreed to;
- a SHA-256 cryptographic hash of the document's title, summary and full text as published;
- the date and time;
- a snapshot of your name, email address and role at that time;
- the IP address from which you agreed, as reported to our servers by our network infrastructure; and
- your browser's user-agent string, which typically identifies your browser, its version and your operating system.

Agreement records are append-only: the Portal does not allow them to be changed or deleted, except that the link to your login is removed if your login is deleted. They are retained even if your login is later deleted, together with the snapshot of your name, email address and role (Section 9). The Portal shows you when you agreed to each version, and you may request a copy of your full agreement records (Section 11). Administrators can view and export all agreement records. Only you can agree, and only in the Portal; a Connected App cannot agree on your behalf.

### 3.5 Content You Provide

We collect the information you submit to the Portal (**"User Content"**). Each item of User Content is stored with your identity as its author, the time it was created and, where applicable, the account it relates to. Depending on your role and the features available to you, User Content includes:

- **Notes** (where enabled): the text of notes you write on an account.
- **Dealer contacts:** for contacts you add or edit, the person's name, title, phone number, email address, whether they are the primary contact, and free-text relationship notes.
- **Activity logs** (where enabled): the type of activity (such as a call, visit or email), its date and any note.
- **Visit reports** (where enabled): visit type and date, inventory level, ratings, store traffic, competitor promotions, competition seen and comments.
- **Photos** (where enabled): the image file, the account, the caption and the uploader. See "Photo and file metadata" below.
- **Call outcomes and call-list responses** (where enabled): the outcome or reaction you record, the reason and any note.
- **Tasks** (where enabled): title, due date and status.
- **Recommendation responses** (where enabled): outcomes and notes you record on recommendations and assigned account lists.
- **Account goals and account deactivations:** goal amounts and notes, the reasons and notes you give when you deactivate (take out of play) or reactivate an account in the Portal, and who created or changed each and when.
- **Orders and order drafts** (where enabled): customer purchase-order number, notes, ship-to selection, the FFL number and expiration date you confirm (and a snapshot of the FFL on file), buyer and purchase-order contact names, phone numbers and email addresses, prices and price-override reasons, and who created, entered and acknowledged the order. For an order created from an email, we also collect the sender, subject, date received, message identifier and an excerpt of up to 4,000 characters.
- **Order documents** (where enabled): files attached to an order (such as PDFs, office documents, spreadsheets, text files, saved email messages and images, up to 25 MB each), uploaded exactly as provided, including their file names and any embedded metadata, and the identity of the uploader.
- **Help and support requests:** the subject, category and text of your questions and the replies. The Portal also attaches the address of the screen you asked from, including any query string (which can contain a search term you entered on that screen, such as an order lookup), your browser's user-agent string, your browser window size, your browser language, whether you were online and the time.
- **AI feedback:** your rating of an AI-generated item and any note you add.

**Photo and file metadata.** Photos taken with a phone or camera often contain embedded metadata (known as EXIF data). This metadata may include the GPS location where the photo was taken, the date and time, and details of the device. The Portal removes this metadata only when it compresses a photo before upload.

**The Portal does not remove photo metadata, including location data, when the photo is 0.3 MB or smaller, when the file is not recognized as an image, when compression cannot run (for example, with some HEIC files or in some cases while offline), or when compression does not reduce the file's size. Images and other files attached as order documents are always uploaded with their metadata intact.** The Portal does not read or use photo metadata, but anyone who can download the file may be able to read it. If you do not want to share location data, turn off location tagging in your camera settings before taking photos for the Portal.

### 3.6 Claude and Other Connected Apps

If available to you, you may connect Claude, an AI assistant provided by Anthropic, or, only if Christensen Arms has approved it in writing as the Terms require, another compatible application (each, a **"Connected App"**) to the Portal through its Model Context Protocol (MCP) connector. You connect either by creating a personal access token on the Connect Claude page or by approving the app's connection request. We collect:

- **Access tokens:** the name you give the token, its first 12 characters, a SHA-256 hash of the token, who created it and when, its expiration date (between 1 and 730 days after creation), when it was last used (updated no more than once every five minutes), whether and by whom it was revoked, and its permissions. We do not store the token itself in the Portal's database, and it is displayed to you only once. If you use the form of connector address that contains the token, the token is carried in that address and may be recorded in our hosting providers' request logs (Section 3.10) and in the Connected App's own records.
- **App connections:** the connected app's client identifier and when the connection was first and last used.
- **Order-drafting logs** (if order drafting through a Connected App is enabled for you): each request to create, update or cancel an order draft or to attach an order document. Each is logged with the time, the User, the token or connection used, the tool name, the arguments of the request (subject to the exclusions described in the next item), the outcome, any error message and the order identifier.
- **What the logged arguments may contain:** purchase-order details, buyer contact names, email addresses and phone numbers, notes, and the sender, subject and excerpt (up to 4,000 characters) of any email you give the Connected App. Document contents are not logged; only the file name, size and a hash are. FFL numbers, and any prices that a User other than an Administrator or a member of Inside Sales tries to set, are left out of the log. The expected price you give for an order line, which the Portal compares with the price list, is kept, as are line prices and price-override reasons set by an Administrator or a member of Inside Sales. A request too large to log in full (more than about 20,000 characters after these exclusions) is logged only by its size and the names of its fields.
- **Read-only requests:** requests that only retrieve information, such as looking up accounts, sales or orders, are not individually logged in our database. The only record of them in our database is the "last used" time described above. Our hosting providers' request logs and any error messages (Section 3.10) may also reflect them.

Section 7.7 describes what a Connected App can receive from the Portal.

### 3.7 AI Usage Records

Each time the Portal generates an AI summary or brief for you, we record your user identifier, the type of AI action and the time. We use these records to enforce a daily limit for each User. Section 8 describes AI processing.

### 3.8 View-As and Administrative Audit Records

An Administrator may view the Portal as another active User (**"View-As"**), as described in Section 7.1. For each View-As session, we record the Administrator, the User viewed, when the session started and, if the Administrator ended it, when it was stopped. A session that is not stopped ends without a separate record, either when it expires after 12 hours or when the Administrator starts viewing as another User. You cannot see these records, and the Portal does not notify you when an Administrator views the Portal as you. Our server logs also record administrative actions, such as creating or updating User accounts, including which Administrator made each change.

### 3.9 Information from Christensen Arms Business Systems

We load the following information into the Portal from the ERP:

- **Business information:** information about dealers, customers, products, prices, inventory, orders, shipments, invoices and sales. This includes sales attributed to your sales representative code, your Book, and your goals and performance.
- **Your representative record:** if you are a sales representative in the ERP, your name, representative code and type, territory and Agency or vendor association. The record also includes your employee identifier, email address, phone number, pay method, commission rates, earning code and related accounting codes. Invoice and shipment records include commission amounts and rates.

Some of these fields are stored in the Portal's database but withheld by access controls from every User, including Administrators. They are the employee identifier, email address, phone number, pay method, commission rates, earning code and accounting codes in your representative record, and the commission amounts and rates on invoice and shipment records. The one exception is a limited administrative tool used to set up new accounts, which displays the ERP email address of sales representatives who do not yet have a Portal login. Section 7.4 describes which other Users can see the fields of your representative record that are not withheld. Sales, performance and other figures shown in the Portal are not commission statements or official statements of account. When an order is submitted in the Portal, it is transferred into the ERP, together with its buyer contact and FFL information.

### 3.10 Information Our Service Providers Process Automatically

When your device communicates with the Portal, our hosting providers (Section 7.6) automatically process technical information in the ordinary course of providing their services, and may record it in their request logs. This includes your IP address, the date and time of the request, the full web address (URL) requested and your browser's user-agent string. A web address can include the text of a search (Section 3.3) or, if you use a connector address that contains a token, the token (Section 3.6). These logs and records are generated by our providers' systems. We do not determine their content, and their retention is governed by the providers' settings and terms.

The Portal's server-side functions also write operational logs to our hosting provider. These logs may include: your user identifier or an account identifier; the AI model used and the amount of text processed when AI content is generated; error messages, without the arguments of Connected App requests; and records of administrative actions. They do not include the content of AI prompts or responses for successful requests.

### 3.11 Information About Dealer Contacts and Other Third Parties

The Portal contains, and allows you to enter, information about individuals who are not Users. These include employees and other contacts of dealers and customers, buyers and contacts named on orders, holders of federal firearms licenses (with their license numbers and expiration dates), senders of emails used to create orders, and individuals who appear in photos. Contact information may include names, titles, office and mobile phone and fax numbers, email and postal addresses, links to professional or social-media profiles, and do-not-call and do-not-email preferences. Some customer accounts may relate to individual purchasers rather than businesses (for example, accounts in direct-to-consumer, employee, pro-staff, law-enforcement or military programs). We process this information for business-to-business purposes in connection with Christensen Arms' relationships with its dealers and customers.

When you enter information about another person: (a) enter only accurate, business-relevant information; (b) do not enter sensitive information, such as government identification numbers, financial account numbers, or health, biometric or similar information, unless a Portal field expressly requires it; and (c) honor do-not-call and do-not-email preferences and the Terms. Information about dealer contacts is visible to everyone whose Book includes the account (Section 7.4) and may be returned to a Connected App (Section 7.7). If a dealer contact or other individual asks you about their information, refer the request to an Administrator.

## 4. Information Stored on Your Device

So that it works in the field, including where connectivity is poor, the Portal stores the information below in your browser's storage on each device you use. **THE PORTAL DOES NOT ENCRYPT THIS INFORMATION ON YOUR DEVICE. IT IS PROTECTED ONLY BY THE SECURITY OF YOUR DEVICE AND BROWSER PROFILE.**

- **Sign-in session:** your session tokens and basic account details (your user identifier, email address and profile information). They are removed when you sign out or when the session is rejected. The Portal does not sign you out automatically after a period of inactivity.
- **Offline copy of account data (sales representatives, including Principals, only):** a copy of data for your Book (for a Principal, the Agency's Book), together with your profile. It includes revenue, orders, shipments, backlog, product sales and stock availability, and account details such as addresses, credit status and credit limit, payment terms, FFL numbers and expiration dates, and invoice and statement email addresses. The Portal does not use a copy that is more than 24 hours old, and it deletes or replaces an expired copy the next time you open the Portal on that device with a network connection. Until then, an expired copy remains in your browser's storage. The copy is also deleted when you sign out, when a different User signs in, when your session is revoked or when your role changes. It is not created for Administrators or Inside Sales, or during View-As.
- **Visit drafts** (where enabled): a visit report you have started but not saved, including ratings, comments and competition seen. It is kept until you save or discard it. It is not removed when you sign out and does not expire.
- **Unsent visits and photos** (where enabled): visits, activity logs and photos that you save for later while offline, or that failed to send. They are kept until they are sent successfully. They are not removed when you sign out and do not expire, and items that cannot be sent stay on the device. If another User signs in on the same browser, your unsent items are not sent under that User's login, but they remain stored on the device.
- **Recently opened accounts:** the identifier and name of up to eight accounts you opened recently, and when. Not removed when you sign out.
- **Starred plan:** up to 50 accounts you have starred, kept until you unstar them. Not removed when you sign out.
- **Activity-seen marker:** when you last looked at the activity feed. Not removed when you sign out.
- **Pending call marker** (where enabled): when you tap Call for a dealer, your user identifier, the account identifier and name, the dealer contact's name and the time, so the Portal can ask you to log the outcome. Removed when you log an outcome or choose "Not now," or, once 30 minutes have passed, the next time the Portal checks for it.
- **App-open timestamp:** the time of your last app-open sign-in record (Section 3.2). Not removed when you sign out.
- **Agreement marker:** the versions of this Policy and the Terms you have agreed to, and when, so the Portal can open offline. Not removed when you sign out.
- **Temporary interface state:** a few settings for the current browser tab, removed when the tab is closed.
- **Cached app code:** the Portal's own program files, so that it loads quickly and can be installed as an app. The cache contains only those program files, and no account data or other information about you. It is stored when you first visit any Portal page, including the sign-in page, and replaced when a new version is released.
- **Files you download:** CSV and XLSX exports, which are generated on your device, and any price sheets, order documents and photos you download or save from the Portal. They are saved wherever your browser or device saves downloads. We do not keep copies of the exports you generate, and we cannot delete any downloaded file from your device.

Signing out removes your sign-in session and the offline copy of account data, including an expired copy. To remove the other items, discard any drafts, clear the site data for carms.app in your browser or device settings and delete any downloaded files. Clearing site data permanently deletes any unsent visits and photos. See Section 10 regarding shared devices.

## 5. Cookies, Tracking Technologies and Advertising

The Portal does not use cookies for advertising, analytics or tracking. Your sign-in session is kept in browser storage (Section 4), not in a cookie. The Portal includes no third-party analytics, advertising, session-replay or error-reporting tools, and it does not load third-party scripts or fonts. The Portal collects Usage Telemetry itself and stores it only in the Portal's own systems, which our service providers host.

**WE DO NOT SELL PERSONAL INFORMATION. WE DO NOT SHARE IT FOR CROSS-CONTEXT BEHAVIORAL ADVERTISING, AND WE DO NOT USE IT FOR TARGETED ADVERTISING.** The Portal does not track Users across third-party websites or services, so it does not respond differently to "Do Not Track" signals. Because we do not sell or share Personal Information, opt-out preference signals such as Global Privacy Control have no additional effect.

## 6. How We Use Information

We use the information described in this Policy for the following business purposes:

- **Operating the Portal:** providing, operating and maintaining the Portal. This includes displaying your Book, generating reports, loading data from the ERP and transferring orders to it, processing orders and order documents, and enabling the Connected Apps that Users choose to use.
- **Authentication and security:** authenticating Users, enforcing access controls, and protecting the Portal and Christensen Arms' information against unauthorized access, misuse, fraud and security incidents.
- **Audit and investigation:** keeping audit trails, and investigating security incidents, complaints, disputes, suspected violations of the Terms or Other Agreements, and suspected unauthorized use or disclosure of confidential information.
- **Support:** responding to help requests, troubleshooting and communicating with you about the Portal.
- **Adoption and performance:** measuring the adoption, engagement and performance of Users, Agencies and territories. For Christensen Arms employees, this includes coaching and performance management. For independent sales representatives and Agency personnel, this includes coaching on the use of the Portal, evaluating account coverage and assessing the Agency's performance under the applicable Other Agreements. It does not give Christensen Arms any right to control the manner or means by which you or your Agency perform your work beyond what an Other Agreement provides.
- **Improvement:** analyzing how the Portal is used in order to improve and develop the Portal and its features, including its AI features.
- **AI features:** generating AI summaries and briefs (Section 8).
- **Enforcement and protection:** enforcing the Terms and Other Agreements, and protecting the rights, property and safety of Christensen Arms, Users, dealers, customers and others.
- **Legal compliance:** complying with applicable laws, regulations and legal process. These include laws governing the firearms industry (such as federal firearms licensing and recordkeeping requirements), export-control and sanctions laws, and tax and accounting requirements.
- **Business records:** maintaining business, accounting and corporate records, and establishing, exercising and defending legal claims.

The Portal does not make decisions about Users' employment, engagement, performance or compensation based solely on automated processing; people review and act on activity and usage reports. We may create aggregated or de-identified information from the information described in this Policy and use it for any lawful purpose. We will keep de-identified information in de-identified form and will not attempt to re-identify it, except as permitted by law.

## 7. Who Can See or Receive Information

What each person can see in the Portal depends on their role and Book. Access controls in the Portal's database enforce these limits, not just the Portal's screens. **YOUR USER CONTENT IS NOT PRIVATE TO YOU. THE PERSONS DESCRIBED IN THIS SECTION CAN SEE IT.**

### 7.1 Christensen Arms Administrators

Administrators have access to all information in the Portal other than the fields withheld from every User (Section 3.9), including:

- every User's profile, including email address, role, sales representative code and Agency;
- every account and order, and all User Content on them;
- every User's tasks, which Administrators can also create, change and delete;
- sign-in records, AI usage records, Connected App records (other than token hashes), order-drafting logs, help requests, AI feedback and agreement records, including the IP addresses and user-agent strings those records contain;
- Usage Telemetry (which, within the Portal, only Administrators can view), including the usage report described below;
- activity and execution views showing, for each User, the most recent sign-in, the number of sign-ins and logged activities in the past 30 days, overdue assigned work and account coverage; and
- the ability to export reports, including usage reports and agreement records, as CSV or XLSX files.

**Usage report.** The usage report covers any period of up to 365 days. For each User, it shows name, email address, role, Agency, sales representative code, number of page views, active days, page views on a phone, accounts viewed, downloads and most-viewed screen. It also shows the most-viewed accounts and actions, and up to the 200 most recent individual events, each with the User, screen, account, device class and event details. Administrators can limit the report to a single User, in which case it shows that User's individual events. Administrators' own activity is recorded but left out of the report unless an Administrator chooses to include it.

**View-As.** Administrators can view the Portal as any active User, including another Administrator, a member of Inside Sales or a Principal. During View-As, the Administrator sees your Book as you see it, together with your tasks, your stored AI briefs and your call-list responses. View-As is read-only: the Administrator cannot create, change or delete anything as you. It expires after no more than 12 hours and is recorded as described in Section 3.8. **YOU ARE NOT NOTIFIED WHEN AN ADMINISTRATOR VIEWS THE PORTAL AS YOU.** The Administrator's View-As session creates no Usage Telemetry or sign-in records. Your own use of the Portal at the same time is recorded as usual. View-As does not display your Connected App tokens, sign-in records or AI usage records, although Administrators can review sign-in and AI usage records directly.

**Administration.** Administrators also create, update and deactivate accounts. They grant and remove access to accounts, turn order drafting through Connected Apps on and off, and delete User Content. Administrators also have the technical ability to issue a Connected App access token for another User's account. Such a token would operate with that User's access and would record the Administrator who created it.

### 7.2 Inside Sales

Inside Sales can read every account and all User Content on it, and every order, including drafts. They can create, price and submit their own orders. They also process orders submitted by other Users, which records them as the person who entered or acknowledged each order, and they can attach and remove order documents. Inside Sales can see the name and role (but not the email address) of any User, for example as the owner of an order. Inside Sales cannot see your tasks, Usage Telemetry or sign-in records, or the activity, coverage and Agency views described in Sections 7.1 and 7.3.

### 7.3 Your Agency Principal

If you are associated with an Agency, the Agency's Principal can see:

- every account in the Agency's Book and all User Content on those accounts, including notes, contacts, activity logs, visit reports, photos, goals, orders and order drafts, regardless of who wrote them; and
- an activity summary for each User associated with the Agency, described below.

The activity summary shows, for each such User:

- name and sales representative code;
- whether the User is a Principal and whether the account is active;
- the time of the most recent sign-in;
- the number of sign-ins in the past 7 and 30 days, and the number of days with a sign-in in the past 30 days;
- the number of activity logs and visits in the past 30 days on accounts in the Principal's Book; and
- the date of the most recent logged activity.

A Principal cannot use these features to see your email address, Usage Telemetry, tasks or AI briefs. Information a Principal obtains through the Portal remains Christensen Arms' confidential information and may be used only as the Terms and the applicable Other Agreements permit.

### 7.4 Other Users Who Share an Account

User Content is shared by account, not by author. Every User whose Book includes an account can see what you write on that account and may be able to identify you as its author. These Users include other sales representatives assigned to or granted access to the account, Principals, Inside Sales and Administrators. What they can see includes notes, contacts, activity logs, visit reports, photos, goals, orders and order documents. Other sales representatives whose Book includes the account can change some User Content, such as account goals and dealer contacts. Users who can read an order can see the name and role of its owner and can attach documents to it. You can likewise see what others, including Principals, write on accounts in your Book. This content may also reach those Users' Connected Apps (Section 7.7), and all of those Users can see the AI summaries generated from it (Section 8).

Your ERP representative record is also visible to other Users. The fields that are not withheld (Section 3.9), namely your name, representative code and type, territory and Agency association, can be seen by your Principal (for every representative of the Agency), by Administrators and Inside Sales (for every representative), and by other Users whose Book includes an account assigned to you in the ERP (for example, as the assigned representative on an account screen). Your ERP name is also included in AI account summaries (Section 8.1).

### 7.5 Christensen Arms Personnel, Affiliates and Systems

Authorized Christensen Arms personnel and contractors who build, operate, maintain and support the Portal have access, for those purposes, to its underlying database, file storage and logs. This includes information withheld from Users. They may use software development and database tools, including AI-assisted tools, in this work. An order-integration process that has access to all accounts and orders transfers submitted orders into the ERP, including their buyer contact and FFL information. We may also share information within Christensen Arms and its affiliates for the purposes described in Section 6.

### 7.6 Service Providers

We use the following service providers to host and operate the Portal. They process information on our behalf under their terms with us.

- **Supabase** hosts the Portal's database, authentication service, file storage (including photos and order documents), server-side functions and related logs. Its authentication service handles sign-in sessions, password storage, Connected App approvals and password-reset emails, which are sent through its configured email delivery service. Supabase therefore processes every category of information described in this Policy that reaches our systems, but not information kept only on your device (Section 4) or sent by your device directly to the third parties described in Section 7.8.
- **Vercel** hosts and delivers the Portal's web application files at carms.app and processes related request information, such as IP addresses and request logs. We do not use Vercel's analytics features.
- **OpenAI** generates in-Portal AI summaries and briefs from the information described in Section 8.

Where configured, messaging or monitoring services also receive technical status alerts about the jobs that load ERP data into the Portal. Each service provider's own security logs and retention practices are governed by its terms and policies.

### 7.7 Anthropic and Other Connected Apps

The Portal itself never sends information to Anthropic. Anthropic, or the provider of another Connected App, receives Portal information only when a User connects a Connected App and it retrieves information on that User's behalf. A Connected App can retrieve only what the connecting User's role and Book permit, and a Connected App used by an Administrator or Inside Sales can retrieve information on every account. Because User Content is shared by account (Section 7.4), what you write on an account, including notes, activity-log notes, visit-report comments and dealer contacts you enter (without your name as author), may reach another User's Connected App even if you never connect one.

A Connected App can retrieve:

- the connecting User's name, role, sales representative code and Agency;
- depending on the permissions approved when connecting, that User's email address and any phone number associated with their sign-in account;
- accounts, sales, product sales, backlog, orders, shipments, invoices, stock, goals and recommendations;
- notes, activity-log notes and visit-report comments written by any User on those accounts;
- dealer contacts, including names, titles, phone numbers, email addresses and notes;
- ship-to addresses with FFL numbers and expiration dates;
- price-list prices; and
- links, valid for 10 minutes, to download order documents.

If order drafting is enabled for a User, that User's Connected App can also send order-draft details, email information and documents to the Portal (Section 3.6). Information a Connected App retrieves is held in the connecting User's account with that app's provider. That provider processes it under that User's agreement with the provider (for Claude, Anthropic's terms and privacy policy), not under this Policy, and Christensen Arms does not control how the provider uses or retains it. The Connected App holds its own credentials for the connection. Until you have agreed to the current versions of this Policy and the Terms, the Portal refuses your Connected App's tool requests, although it still records when the connection was last used (Section 3.6). You may revoke your tokens and disconnect your apps at any time on the Connect Claude page. Use of Connected Apps is subject to the Terms.

### 7.8 Third Parties You Choose to Contact or Share With

When you choose to use certain links or sharing features, your device sends information directly to the third party involved, which processes it under its own terms and policies. Your device also sends the technical information it ordinarily sends, such as your IP address.

- **Google Maps:** a dealer's address when you request directions, or the addresses of up to 10 starred dealers when you route several at once.
- **UPS:** a tracking number when you open shipment tracking.
- **christensenarms.com:** the product identifier in the link when you open a product page, subject to that website's own policies.
- **Your device's phone, messaging, email and sharing apps:** the phone numbers, email addresses and order-status text you choose to call, message, email or share, and the recipients you choose.

### 7.9 Legal, Compliance and Safety Disclosures

We may access, preserve and disclose information, including User Content, if we believe in good faith that doing so is necessary or appropriate to: (a) comply with applicable law, regulation, subpoena, court order or other legal process, or respond to a lawful request from a governmental, regulatory or law-enforcement authority (including the Bureau of Alcohol, Tobacco, Firearms and Explosives); (b) comply with firearms, export-control and sanctions requirements; (c) enforce the Terms and Other Agreements; (d) detect, investigate, prevent or address fraud, security incidents, misuse of the Portal, or unauthorized use or disclosure of confidential information; (e) protect the rights, property or safety of Christensen Arms, Users, dealers, customers or the public; or (f) communicate with your Agency or employer where relevant to an investigation or to the administration or enforcement of an Other Agreement. We may also disclose information to our auditors, legal counsel, insurers and other professional advisers who are bound by duties of confidentiality.

### 7.10 Corporate Transactions

We may disclose and transfer information, subject to applicable law, in connection with an actual or proposed merger, acquisition, financing, reorganization, divestiture, bankruptcy, sale of all or part of our business or assets, or similar transaction, including during due diligence.

### 7.11 At Your Direction

We may also disclose information at your direction or with your consent.

## 8. AI Processing

### 8.1 In-Portal AI Summaries and Briefs (OpenAI)

The Portal uses OpenAI's services to provide two kinds of AI-generated content:

- **Account summaries** are generated when you press Summarize on an account. They are also generated automatically for some accounts during a nightly process.
- **Territory briefs** are generated automatically the first time you open the Overview screen each day, if that day's brief has not yet been created. They are not generated automatically in some circumstances, such as during View-As. For Administrators, the brief covers the whole company.

**What an account summary sends to OpenAI:**

- the account's name, city and state, and the name of the sales representative assigned to it in the ERP;
- the account's type, territory and key dates, and its goal and pace;
- its year-to-date revenue and monthly revenue history, product-family mix, recent orders, open orders and backlog, and reorder candidates;
- open and resolved recommendations, including outcome notes;
- the date and type of the most recent logged activity;
- the text of up to five of the most recent notes on the account, without their authors; and
- the most recent visit report, including its comments and competition seen.

Account summaries do not include dealer contacts or the identity of the authors of notes, visit reports or activity logs.

**What a territory brief sends to OpenAI:** the Book's totals and goals; lists of top, changing and dormant accounts, with each account's name, city, state and revenue; product mix; recent large orders; and dates showing how current the data is.

Requests to OpenAI do not include a user identifier or similar tracking parameter, and territory briefs do not include your name, email address or user identifier. However, the information sent may itself include Personal Information. Account summaries include the name of the sales representative assigned to the account in the ERP, which may be you. They also include whatever Users write in notes, visit-report comments and recommendation notes. **DO NOT INCLUDE IN NOTES, COMMENTS OR OTHER USER CONTENT ANY INFORMATION YOU WOULD NOT WANT PROCESSED BY AN AI SERVICE PROVIDER.** OpenAI processes this information to generate the requested output under its terms with us. OpenAI's retention of that information is governed by those terms, which this Policy does not describe.

**Storage and visibility of outputs.** Account summaries are stored with a record of which User generated them, and every User whose Book includes the account can see them. Territory briefs are stored for the User they were generated for, and Administrators can see them through View-As. AI outputs are not stored on your device. AI-generated content may be incomplete or inaccurate and must be verified as the Terms require. We keep AI usage records (Section 3.7) and any feedback you give on AI content (Section 3.5).

### 8.2 Claude and Other Connected Apps (Anthropic)

Anthropic does not generate the Portal's own AI summaries and briefs. Apart from any AI-assisted development and support tools that authorized personnel use as described in Section 7.5, Anthropic receives Portal information only through a Connected App that you or another User connects, as described in Sections 7.4 and 7.7, and processes it under that User's own agreement with Anthropic. Section 3.6 describes the records we keep about Connected App use.

## 9. Retention

We retain Personal Information for as long as reasonably necessary for the purposes described in this Policy. These purposes include Christensen Arms' business operations and record-keeping; legal and regulatory compliance (including firearms, export-control, tax and accounting requirements); audit, security and investigations; and the establishment, exercise or defense of legal claims and disputes. To decide how long to retain information, we consider the nature and sensitivity of the information, the purposes for which it is used, how long our relationship with you or your Agency lasts, applicable legal retention requirements and limitation periods, and any legal hold.

The Portal does not currently apply an automatic deletion schedule to sign-in records, Usage Telemetry, AI usage records, Connected App records and order-drafting logs, View-As records, help requests, User Content (including photos and order documents), orders, AI outputs or agreement records. If we adopt a retention schedule, we will describe it in an updated version of this Policy. In addition:

- **Deactivation:** deactivating an account blocks further sign-ins but does not delete the account or any information associated with it. A session already in progress may remain usable for a short period, typically up to about an hour, until its access token expires. Connected App tokens and connections stop working as soon as an account is deactivated.
- **No self-service deletion:** no feature lets a User delete their account.
- **Agreement records:** retained even if your login is later deleted, together with the snapshot of your name, email address and role.
- **User Content:** User Content you contribute to accounts is a Christensen Arms business record and is generally retained after your access ends. Deleting a photo from an account may not delete the underlying image file from storage.
- **Connected App tokens:** tokens expire no later than 730 days after creation, but records of expired and revoked tokens are retained.
- **ERP-derived information:** mirrors the ERP and is removed from the Portal when it is removed from the ERP.
- **View-As sessions:** expire after no more than 12 hours. Their audit records are retained.
- **Backups:** information deleted from the Portal may remain in our hosting providers' backups for a limited period until those backups are overwritten under their standard practices.
- **Information on your device:** retained as described in Section 4, until you remove it, sign out (for the items that signing out removes) or clear the Portal's site data. The Portal stops using the offline copy of account data after 24 hours, and deletes or replaces an expired copy the next time you open the Portal on that device with a network connection.
- **Downloaded files:** you are solely responsible for files you download, and you must handle, secure and dispose of them as the Terms require.
- **Third parties:** our service providers' retention of their own logs, and retention by OpenAI, Anthropic and the other third parties described in Section 7, are governed by their terms and policies.

## 10. Security

We use administrative and technical safeguards designed to protect information in the Portal, including:

- access controls based on role and Book that are enforced in the Portal's database itself;
- encryption of data in transit between your device and the Portal;
- hashed storage of passwords by our authentication provider;
- storage of Connected App tokens in the Portal's database only as a cryptographic hash, with each token displayed once, subject to expiration and revocable at any time (see Section 3.6 regarding connector addresses that contain a token);
- withholding of sensitive ERP fields from all Users;
- private file storage with time-limited download links;
- View-As that is read-only, time-limited and audited; and
- append-only agreement records.

**NO METHOD OF TRANSMITTING OR STORING INFORMATION IS COMPLETELY SECURE. CHRISTENSEN ARMS DOES NOT GUARANTEE THE SECURITY OF ANY INFORMATION AND, TO THE FULLEST EXTENT PERMITTED BY LAW, IS NOT RESPONSIBLE FOR UNAUTHORIZED ACCESS THAT RESULTS FROM YOUR FAILURE TO SAFEGUARD YOUR CREDENTIALS OR DEVICES.**

You are responsible for:

- keeping your password confidential and unique to the Portal, never sharing it, and promptly changing any temporary password (an Administrator may send your initial sign-in details by email);
- securing every device you use with the Portal with a screen lock and current software updates, and avoiding shared or public devices;
- on any device that others use, signing out and clearing the Portal's site data when you finish, bearing in mind that the Portal does not sign you out after inactivity and that signing out does not remove every item stored on the device (Section 4);
- treating Connected App tokens, and any connector address that contains a token, as passwords, never posting or sharing them, and revoking tokens and connections you no longer use;
- approving only connection requests that you started yourself and whose destination you recognize; and
- immediately reporting, through Help & support in the Portal (the ? icon) or to your Christensen Arms sales administrator, any suspected loss, theft or compromise of your credentials or devices and any unauthorized access to the Portal or its information.

If we determine that applicable law requires us to notify you of a security incident, we will notify you as that law requires.

## 11. Your Choices and Rights

**Access and correction.** You may ask for a copy of Personal Information about you, or ask us to correct it, through Help & support in the Portal (the ? icon) or through your Christensen Arms sales administrator. Administrators maintain your profile and access. You cannot view some records in the Portal, such as Usage Telemetry, View-As records and the IP address and user-agent details of your agreement records, but we may provide them on request. Any such request is subject to applicable law and to the protection of others' information and Christensen Arms' confidential information.

**Deletion and editing.** Much User Content cannot be edited or deleted by its author after it is saved. Notes, activity logs and visit reports cannot be edited, and only Administrators can delete them or delete photos. You cannot delete account deactivations, recommendation responses or AI feedback. Depending on your role and the features available to you, you can edit the captions of your photos, manage your own tasks and order drafts, undo call-list responses and remove order documents you uploaded. You, and other Users whose Book includes the account, can edit dealer contacts entered in the Portal and edit or delete account goals. We will consider requests to delete other information in light of Christensen Arms' business, legal and audit retention needs (Section 9) and applicable law.

**Monitoring.** **YOU CANNOT OPT OUT OF THE MONITORING DESCRIBED IN THIS POLICY WHILE YOU USE THE PORTAL.** If you do not agree to this Policy, you may not use the Portal.

**Optional features.** You may choose whether to request account summaries and whether to connect a Connected App, although territory briefs and some account summaries are generated automatically (Section 8.1). You may revoke tokens and disconnect apps on the Connect Claude page at any time. You may also choose which optional User Content to provide and whether your camera records location in photos.

**Your device.** You may sign out, discard drafts, clear the Portal's site data and delete downloaded files, as described in Section 4.

**Your Agency.** For information your Agency holds about you outside the Portal, contact your Agency.

**State privacy rights.** Depending on where you live, you may have additional rights under state privacy laws, as described in Sections 12 and 13.

## 12. Notice to California Residents

This Section supplements this Policy. It applies to Users who are California residents, to the extent that the California Consumer Privacy Act of 2018, as amended by the California Privacy Rights Act of 2020, and its implementing regulations (the **"CCPA"**) apply. That includes Personal Information collected in a workforce or business-to-business context, to the extent the CCPA applies to it. This Policy, including this Section, is our notice at collection.

### 12.1 Categories of Personal Information Collected

In the preceding 12 months, we have collected the categories of Personal Information below, each from the sources and for the purposes described in this Policy:

- **Identifiers:** name, email address, user identifier, sales representative code, Agency or vendor identifier, IP address, Connected App token identifiers and, in ERP records, employee or vendor identifiers.
- **Personal information described in California Civil Code Section 1798.80(e):** name, telephone number (from ERP records or, if you approve it, shared with a Connected App) and employment-related information.
- **Commercial information:** records of orders you create, draft, submit or handle, and sales, invoice and commission information attributed to your sales representative code.
- **Internet or other electronic network activity information:** sign-in records, Usage Telemetry, Connected App records and order-drafting logs, AI usage records, View-As records, browser user-agent strings, device class, help-request device details and our providers' request logs.
- **Geolocation data:** precise location only if your device embeds it in the metadata of a photo or file you upload. We do not use this metadata, and we do not derive your location from your IP address.
- **Audio, electronic, visual or similar information:** photos and documents you upload.
- **Professional or employment-related information:** role, territory, Agency association, sales representative code, goals, sales performance, account coverage, activity measures, and ERP records of pay method, commission rates and commission amounts (stored but withheld from Users).
- **Inferences:** activity and performance measures derived from the information above, such as sign-in frequency, active days, accounts viewed and account coverage, used to assess adoption and performance.
- **Sensitive personal information:** as described in Section 12.2.

We do not intentionally collect characteristics of protected classifications, biometric information or education information. We collect Personal Information from: you; your devices and browsers; Administrators and other Users (for example, User Content that mentions you); the ERP and other Christensen Arms business systems; Connected Apps; and our service providers.

### 12.2 Sensitive Personal Information

The sensitive personal information we collect is limited to:

- your account log-in, meaning your email address together with your password, which our authentication provider stores in hashed form;
- Connected App tokens, which the Portal's database stores only as a hash;
- the contents of email messages you choose to provide to create orders; and
- any precise geolocation your device embeds in the metadata of photos or files you upload.

The Portal is not designed to collect, and we do not request, other sensitive personal information. This includes Social Security, driver's license or passport numbers; financial account credentials; information about racial or ethnic origin, religious or philosophical beliefs, union membership, health, sex life or sexual orientation, or citizenship or immigration status; and genetic or biometric data. We use and disclose sensitive personal information only for the purposes permitted by California Code of Regulations, title 11, section 7027(m), such as providing the Portal, ensuring security and integrity, and complying with law. **WE DO NOT USE OR DISCLOSE SENSITIVE PERSONAL INFORMATION TO INFER CHARACTERISTICS ABOUT YOU.** The right to limit the use of sensitive personal information therefore does not apply to our processing. If that changes, we will update this Policy and honor any applicable request to limit.

### 12.3 Purposes of Collection and Use

We collect, use and disclose each category of Personal Information for the business and commercial purposes described in Section 6. These include performing services, ensuring security and integrity, debugging, short-term transient use, auditing, quality assurance and improvement, and complying with legal obligations.

### 12.4 Disclosures, Sales and Sharing

In the preceding 12 months, we have disclosed Personal Information for a business purpose, or otherwise disclosed it (without selling or sharing it), to the following categories of recipients, and we may continue to do so:

- service providers and contractors, including hosting, authentication and storage providers (all categories) and AI service providers (identifiers, commercial information, professional or employment-related information, and User Content included in AI requests);
- Christensen Arms affiliates;
- your Agency, through its Principal (identifiers, internet or other electronic network activity information, professional or employment-related information, inferences and User Content, as described in Section 7.3);
- other Users outside Christensen Arms, including sales representatives and Principals of other Agencies whose Book includes the same account (identifiers, commercial information, professional or employment-related information and User Content, as described in Section 7.4);
- Connected Apps used by you or, for information on shared accounts, by other Users (Sections 7.4 and 7.7); and
- governmental, regulatory and law-enforcement authorities and professional advisers, where the law requires or permits it.

**WE DO NOT SELL PERSONAL INFORMATION OR SHARE IT FOR CROSS-CONTEXT BEHAVIORAL ADVERTISING, AND WE HAVE NOT DONE SO IN THE PRECEDING 12 MONTHS. WE HAVE NO ACTUAL KNOWLEDGE OF SELLING OR SHARING THE PERSONAL INFORMATION OF CONSUMERS UNDER 16 YEARS OF AGE.**

### 12.5 Retention

We retain each category of Personal Information according to the criteria described in Section 9. The Portal does not currently apply fixed retention periods. Each category is retained for as long as reasonably necessary for the purposes for which it was collected, including business, legal, audit and dispute-resolution purposes, taking into account applicable legal retention requirements and limitation periods.

### 12.6 Your California Rights

Subject to verification and to the exceptions in the CCPA, you have the following rights:

- **Right to know and access:** to request that we disclose the categories of Personal Information we have collected about you, the categories of its sources, our business or commercial purposes for collecting it, the categories of third parties to whom we disclose it, and the specific pieces of Personal Information we have collected about you, in a portable and, to the extent technically feasible, readily usable format.
- **Right to delete:** to request that we delete Personal Information we have collected from you. Exceptions apply, including where we need the information to complete transactions, ensure security and integrity, debug, comply with legal obligations, establish, exercise or defend legal claims, or for internal uses reasonably aligned with your expectations based on your relationship with us.
- **Right to correct:** to request that we correct inaccurate Personal Information about you.
- **Right to limit:** to request that we limit the use and disclosure of sensitive personal information, to the extent that right applies (Section 12.2).
- **Right to opt out of sale or sharing:** we do not sell or share Personal Information, so there is no sale or sharing to opt out of.

### 12.7 How to Submit and Verify a Request

You may submit a request through Help & support in the Portal (the ? icon) or through your Christensen Arms sales administrator. If you no longer have access to the Portal, or you are an authorized agent acting for a User, you may submit a request through the general contact methods published on christensenarms.com, stating that the request concerns the Rep Portal. Before fulfilling a request, we will verify your identity by matching information you provide against information we maintain. We treat a request submitted while you are signed in to your Portal account as coming from you. We may ask you to sign in again before we disclose or delete information in response to a request. We may require additional information, particularly for requests for specific pieces of information or for deletion, and we will use information provided for verification only for that purpose.

We will confirm receipt of a request within 10 business days and respond within 45 calendar days. Where reasonably necessary, we may extend that period by up to an additional 45 calendar days, and we will tell you if we do. If we deny a request in whole or in part, we will explain why, except where the law prohibits us from doing so.

### 12.8 Authorized Agents

You may use an authorized agent to submit a request on your behalf. Unless the agent holds a valid power of attorney under California Probate Code Sections 4121 to 4130, we may require the agent to provide your signed, written permission. We may also require you to verify your identity directly with us and to confirm that you gave the agent permission. We may deny a request from an agent that does not submit proof of authorization. An authorized agent may not sign in to your Portal account to make a request.

### 12.9 Non-Retaliation

We will not discriminate or retaliate against you for exercising any of your rights under the CCPA, including in your capacity as an employee, job applicant or independent contractor.

### 12.10 Disclosures for Direct Marketing

We do not disclose Personal Information to third parties for their own direct marketing purposes, within the meaning of California Civil Code Section 1798.83.

## 13. Residents of Other U.S. States

Residents of certain other states may have rights under their state's consumer privacy laws. These may include the rights to confirm whether we process Personal Information about them, to access it and obtain a portable copy of it, to correct it, to delete it, and to opt out of its sale, its use for targeted advertising and certain profiling. Many of these laws do not apply to information processed in an employment or business-to-business context, including information about individuals acting in a commercial or employment capacity. To the extent such a law applies to you, you may exercise these rights as described in Section 12.7.

If we decline to act on your request, you may appeal by submitting an appeal through the same channels and stating that you are appealing our decision. We will respond within the time the law requires. If we deny your appeal, you may contact your state's attorney general. We do not sell Personal Information, use it for targeted advertising, or engage in solely automated profiling in furtherance of decisions that produce legal or similarly significant effects.

## 14. Children

The Portal is intended solely for business use by adults and is not directed to anyone under 18 years of age. We do not knowingly issue Portal accounts to anyone under 18, or knowingly collect Personal Information through the Portal from anyone under 18. If we learn that we have done so, we will disable the account and take appropriate steps regarding the information, consistent with applicable law.

## 15. Where Information Is Processed

Christensen Arms operates the Portal from the United States and intends that it be used, and its information hosted, in the United States. Our service providers, and the provider of any Connected App a User chooses, may also process information in other countries under their own terms. If you access the Portal from outside the United States, you understand that your information will be transferred to, processed in and stored in the United States, where data-protection laws may differ from those of your jurisdiction.

## 16. Changes to This Policy

We may amend this Policy from time to time. When we publish a new version, the Portal will present it to you, and you must review and agree to it before you can continue to use the Portal. Until you do, the Portal also refuses your Connected Apps' tool requests. Each version of this Policy is retained unchanged, together with the records of who agreed to it. The Portal displays the version and effective date of this Policy alongside it. Once you agree to a new version, it applies, to the extent permitted by law, to information collected both before and after its effective date. If you do not agree, select "Decline and sign out" and stop using the Portal. Information already collected will continue to be handled as described in the version you last agreed to or, if you have not agreed to any version, as described in the current version.

## 17. Contact Us

If you have questions about this Policy or our privacy practices, or wish to make a request under this Policy, contact us through Help & support in the Portal (the ? icon) or through your Christensen Arms sales administrator. If you no longer have access to the Portal, use the methods described in Section 12.7.$privacy$
)
on conflict (doc_key, version) do nothing;
