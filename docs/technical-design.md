التصميم التقني — المرحلة الأولى

نظام إدارة التدريب الميداني الجامعي

المرجع: وثيقة PRD النهائية
الحالة: تصميم أولي للمراجعة؛ لا يغيّر متطلبات الـPRD
اللغة واتجاه الواجهة: العربية، من اليمين إلى اليسار (RTL)
النطاق: مخطط بيانات، عزل بيانات الكليات، مصفوفة صلاحيات، وصف شاشات الطالب الأساسية

────────

1. مبادئ التصميم وحدود هذا المستند

1. المتطلبات الواردة في الـPRD هي المرجع الحاكم. لا يضيف هذا المستند قواعد أعمال جديدة بوصفها قرارات معتمدة.
2. قاعدة البيانات المعتمدة هي PostgreSQL، وتُطبّق سياسات Row-Level Security (RLS) على الجداول ذات نطاق الكلية. يستخدم هذا التصميم الأنواع UUID, TEXT, BOOLEAN, DATE, TIMESTAMPTZ, JSONB, NUMERIC، مع نوع جغرافي مكاني عند الحاجة إلى GIS. تقنية GIS المحددة ما زالت قرارًا لاحقًا.
3. أسماء الحقول أدناه أسماء تقنية مقترحة بصيغة snake_case. القيم والأسماء التي تصف متطلبات العمل تبقى عربية في واجهة الاستخدام.
4. كل الجداول التي تخص كلية تحمل college_id مباشرة أو تصل إليها عبر علاقة لا تقبل الالتباس. تطبق PostgreSQL RLS على الجداول النطاقية، مع تحقق إضافي في خادم التطبيق؛ لا تعتمد الصلاحيات على إخفاء عناصر الواجهة وحده.
5. الجداول التشغيلية تحتفظ بالتواريخ الزمنية بتوقيت UTC؛ تعرض الواجهة الوقت وفق حقل timezone الإلزامي للكلية، الذي يضبطه المسؤول الأعلى عند إضافتها. يحتسب تاريخ الحضور وفق المنطقة الزمنية للكلية.
6. الحقول المشار إليها بأنها «مشتقة» لا يلزم تخزينها إذا أمكن حسابها بشكل موثوق من المصدر. أي حفظ مؤقت لها يجب أن يضمن عدم اختلافها عن السجلات المعتمدة.
7. المصفوفة توضح حدود الوصول المقترحة بحسب الدور وعلاقته بسجل التدريب. أما صلاحية المسؤول الأعلى للوصول الاستثنائي، وآلية التدقيق التفصيلية، فتظل خاضعة للفجوات المدرجة في القسم 6.

2. نموذج البيانات (Database Schema)

2.1 اصطلاحات ومفاتيح عامة

• المفتاح الأساسي المقترح لكل جدول هو id UUID PRIMARY KEY، ما لم يذكر خلاف ذلك.
• جميع مفاتيح العلاقات الخارجية تستخدم FOREIGN KEY مع سياسة حذف محافظة: RESTRICT للسجلات الأكاديمية والتدقيقية، وCASCADE فقط للعناصر التابعة غير القابلة للبقاء وحدها وبعد اعتماد سياسة الاحتفاظ.
• created_at TIMESTAMPTZ NOT NULL وupdated_at TIMESTAMPTZ NOT NULL مقترحان لمعظم السجلات القابلة للتحرير. سجلات التدقيق وسجل تغييرات الملاحظات لا تُحدّث بعد الإنشاء.
• إضافة college_id إلى جدول ذي نطاق كلية هي وسيلة لتسهيل العزل والفهرسة، ويجب التحقق أن القيمة تطابق الكلية المستنتجة من العلاقات أيضًا.
• محرك قاعدة البيانات المعتمد هو PostgreSQL مع تفعيل Row-Level Security (RLS) لعزل بيانات الكليات. جميع الحقول الإلزامية والاختيارية المبينة هنا مقترح مبدئي؛ حقول نماذج الفرصة/الطلب التي أكدها الـPRD محددة بوضوح، وحقول التسجيل الإلزامية المعتمدة مبينة في جدول المستخدمين.

2.2 الجداول الأساسية

2.2.1 colleges — الكليات

|الحقل       |النوع المقترح|القيود/الملاحظات                                                                                                                        |
|------------|-------------|----------------------------------------------------------------------------------------------------------------------------------------|
|`id`        |UUID         |PK                                                                                                                                      |
|`name_ar`   |TEXT         |مطلوب؛ اسم الكلية بالعربية                                                                                                              |
|`status`    |TEXT/ENUM    |مقترح: `active`, `inactive`؛ تمكين/إيقاف الكلية يحتاج اعتماد سياسة                                                                      |
|`timezone`  |TEXT         |NOT NULL؛ اسم منطقة زمنية صالح (مثل معرف IANA)، يضبطه المسؤول الأعلى عند إضافة الكلية. يعتمد تاريخ الحضور المحلي على هذه المنطقة الزمنية|
|`created_at`|TIMESTAMPTZ  |مطلوب                                                                                                                                   |
|`updated_at`|TIMESTAMPTZ  |مطلوب                                                                                                                                   |

العلاقات: كلية واحدة لها مستخدمون وتخصصات ومتطلبات وفرص ومواقع وتدريبات وسجلات ضمن نطاقها. إضافة كلية مخولة للمسؤول الأعلى.

2.2.2 users — المستخدمون

|الحقل                   |النوع المقترح|القيود/الملاحظات                                                                             |
|------------------------|-------------|---------------------------------------------------------------------------------------------|
|`id`                    |UUID         |PK                                                                                           |
|`college_id`            |UUID         |FK → `colleges.id`؛ NULL للمسؤول الأعلى فقط وفق التصميم المقترح                              |
|`email`                 |TEXT         |مطلوب وفريد بعد التطبيع؛ يستخدم لتسجيل الدخول                                                |
|`password_hash`         |TEXT         |مطلوب؛ لا تخزن كلمة المرور كنص صريح                                                          |
|`email_verified_at`     |TIMESTAMPTZ  |NULL قبل تحقق البريد                                                                         |
|`account_status`        |TEXT/ENUM    |مقترح: `pending_activation`, `active`, `rejected`, `suspended`؛ رفض/تعليق الحساب لم يحسمه PRD|
|`first_name`            |TEXT         |NOT NULL؛ إلزامي لكل المستخدمين                                                              |
|`last_name`             |TEXT         |NOT NULL؛ إلزامي لكل المستخدمين                                                              |
|`phone`                 |TEXT         |اختياري وفق قرار PRD-20؛ يمكن إضافته أو تعديله لاحقًا، ولا يشترط لتفعيل الحساب                |
|`student_number`        |TEXT         |NOT NULL للطالب فقط؛ إلزامي. سياسة التفرد/التحقق لم تُحدد                                     |
|`company_name`          |TEXT         |NOT NULL لمسؤول جهة التدريب فقط؛ اسم الشركة                                                  |
|`specialty_id`          |UUID         |FK → `specialties.id`؛ يستخدم للطالب، NULL للأدوار الأخرى                                    |
|`activation_approved_by`|UUID         |FK → `users.id`، nullable؛ مسؤول الكلية الموافق                                              |
|`activation_approved_at`|TIMESTAMPTZ  |nullable                                                                                     |
|`created_at`            |TIMESTAMPTZ  |مطلوب                                                                                        |
|`updated_at`            |TIMESTAMPTZ  |مطلوب                                                                                        |

قيود: فهرس فريد على البريد بعد التطبيع. الاسم الأول والأخير إلزاميان لكل الأدوار؛ الرقم الجامعي إلزامي للطالب، واسم الشركة إلزامي لمسؤول جهة التدريب. يفرض الخادم هذه القيود بحسب الدور. يرتبط كل حساب بكلية واحدة وفق قرار PRD-12؛ ويجوز لمسؤول جهة التدريب إدارة عدة مواقع تابعة للشركة نفسها، لا شركات مستقلة متعددة.

2.2.3 roles — تعريفات الأدوار

|الحقل    |النوع المقترح|القيود/الملاحظات                                                                                 |
|---------|-------------|-------------------------------------------------------------------------------------------------|
|`id`     |SMALLINT/UUID|PK                                                                                               |
|`code`   |TEXT         |فريد: `student`, `academic_supervisor`, `company_representative`, `college_admin`, `system_admin`|
|`name_ar`|TEXT         |مطلوب                                                                                            |

الأدوار المحددة ثابتة في المرحلة الأولى، ويمكن تمثيلها بقيم ENUM بدل جدول. يُفضل جدول مرجعي إن كانت إدارة الأدوار قابلة للتوسع.

2.2.4 user_roles — إسناد الأدوار

|الحقل       |النوع المقترح|القيود/الملاحظات                            |
|------------|-------------|--------------------------------------------|
|`user_id`   |UUID         |FK → `users.id`                             |
|`role_id`   |SMALLINT/UUID|FK → `roles.id`                             |
|`college_id`|UUID         |FK → `colleges.id`؛ NULL لدور المسؤول الأعلى|
|`granted_by`|UUID         |FK → `users.id`؛ المسؤول الذي فعّل/أسند الدور|
|`granted_at`|TIMESTAMPTZ  |مطلوب                                       |
|`status`    |TEXT/ENUM    |مقترح: `pending`, `active`, `revoked`       |

المفاتيح: PK مركب (user_id, role_id, college_id) أو id UUID مع قيد فريد مكافئ.
ملاحظة: إذا كان لكل مستخدم دور واحد فقط، يمكن تبسيط التصميم إلى حقل role داخل users. جدول الربط يفيد في حالة تعدد الأدوار، لكنها لم تحسم في PRD.

2.2.5 specialties — التخصصات

|الحقل       |النوع المقترح|القيود/الملاحظات                   |
|------------|-------------|-----------------------------------|
|`id`        |UUID         |PK                                 |
|`college_id`|UUID         |FK → `colleges.id`, NOT NULL       |
|`name_ar`   |TEXT         |مطلوب                              |
|`code`      |TEXT         |اختياري؛ فريد داخل الكلية إن استخدم|
|`is_active` |BOOLEAN      |مطلوب                              |
|`created_at`|TIMESTAMPTZ  |مطلوب                              |
|`updated_at`|TIMESTAMPTZ  |مطلوب                              |

قيد فريد مقترح: (college_id, name_ar) أو (college_id, code). لا يُحذف تخصص مرتبط بسجلات تاريخية؛ يعطل بدلًا من ذلك.

2.2.6 specialty_training_requirements — متطلبات التدريب حسب التخصص

|الحقل                     |النوع المقترح|القيود/الملاحظات                                                       |
|--------------------------|-------------|-----------------------------------------------------------------------|
|`id`                      |UUID         |PK                                                                     |
|`college_id`              |UUID         |FK → `colleges.id`, NOT NULL                                           |
|`specialty_id`            |UUID         |FK → `specialties.id`, NOT NULL؛ فريد مبدئيًا                           |
|`minimum_total_minutes`   |INTEGER      |NOT NULL؛ الحد الأدنى للساعات محول إلى دقائق لتجنب الكسور العائمة      |
|`training_duration_days`  |INTEGER      |NOT NULL؛ مدة التدريب بحسب وحدة الأيام، لكن وحدة/تعريف المدة يحتاج ضبطًا|
|`daily_work_limit_minutes`|INTEGER      |NOT NULL؛ الحد اليومي بالساعات محول إلى دقائق                          |
|`created_at`              |TIMESTAMPTZ  |مطلوب                                                                  |
|`updated_at`              |TIMESTAMPTZ  |مطلوب                                                                  |

العلاقات: تخصص واحد له متطلبات معتمدة. إذا احتاجت الكلية تاريخ سريان/نسخًا مختلفة، يضاف إصدار مؤرخ؛ تطبق المتطلبات الجديدة على التدريبات الجديدة فقط؛ تحتفظ التدريبات القائمة بنسخة متطلباتها عند البداية وفق قرار PRD-07.

2.2.7 training_opportunities — فرص التدريب

|الحقل               |النوع المقترح|القيود/الملاحظات                                               |
|--------------------|-------------|---------------------------------------------------------------|
|`id`                |UUID         |PK                                                             |
|`college_id`        |UUID         |FK → `colleges.id`, NOT NULL                                   |
|`created_by_user_id`|UUID         |FK → `users.id`; يجب أن يكون مسؤول جهة تدريب مفعلًا             |
|`title`             |TEXT         |NOT NULL؛ عنوان الفرصة                                         |
|`task_description`  |TEXT         |NOT NULL؛ وصف المهام                                           |
|`start_date`        |DATE         |NOT NULL                                                       |
|`end_date`          |DATE         |NOT NULL؛ قيد `end_date >= start_date`                         |
|`seat_limit`        |INTEGER      |NOT NULL؛ عدد موجب يحدده مسؤول الشركة، ويجب أن يكون أكبر من صفر|
|`status`            |TEXT/ENUM    |`open`, `closed` وفق PRD                                       |
|`created_at`        |TIMESTAMPTZ  |مطلوب                                                          |
|`updated_at`        |TIMESTAMPTZ  |مطلوب                                                          |

فهارس مقترحة: (college_id, status, start_date), وFK المنشئ. لا تُعرض فرصة إلا لطلاب الكلية نفسها والتخصصات المرتبطة بها عندما تكون مفتوحة، وغير ممتلئة.

2.2.8 opportunity_specialties — التخصصات المستهدفة للفرصة

|الحقل           |النوع المقترح|القيود/الملاحظات                              |
|----------------|-------------|----------------------------------------------|
|`opportunity_id`|UUID         |FK → `training_opportunities.id`              |
|`college_id`    |UUID         |FK → `colleges.id`؛ لتثبيت النطاق وفحص الاتساق|
|`specialty_id`  |UUID         |FK → `specialties.id`                         |

المفتاح: (opportunity_id, specialty_id). كل تخصص مستهدف يجب أن يكون تابعًا للكلية نفسها.

2.2.9 training_sites — مواقع التدريب

|الحقل                          |النوع المقترح|القيود/الملاحظات                                                                  |
|-------------------------------|-------------|----------------------------------------------------------------------------------|
|`id`                           |UUID         |PK                                                                                |
|`college_id`                   |UUID         |FK → `colleges.id`, NOT NULL                                                      |
|`created_by_user_id`           |UUID         |FK → `users.id`؛ مسؤول الشركة                                                     |
|`name`                         |TEXT         |اختياري/مستحسن لتمييز المواقع                                                     |
|`address_text`                 |TEXT         |وصف/عنوان بشري                                                                    |
|`latitude`                     |NUMERIC(9,6) |إحداثية الموقع                                                                    |
|`longitude`                    |NUMERIC(9,6) |إحداثية الموقع                                                                    |
|`geofence_radius_meters`       |INTEGER      |الافتراضي 150، قابل للتعديل بواسطة مسؤول الكلية، موجب                             |
|`gps_accuracy_threshold_meters`|INTEGER      |قيمة التصميم 100 متر وفق PRD؛ تحفظ كإعداد مركزي أو ثابت، ولا يلزم تكرارها لكل موقع|
|`approval_status`              |TEXT/ENUM    |`pending`, `approved`, `rejected`                                                 |
|`approved_by_user_id`          |UUID         |FK → `users.id`, nullable                                                         |
|`approved_at`                  |TIMESTAMPTZ  |nullable                                                                          |
|`created_at`                   |TIMESTAMPTZ  |مطلوب                                                                             |
|`updated_at`                   |TIMESTAMPTZ  |مطلوب                                                                             |

2.2.10 opportunity_sites — ربط الفرصة بالمواقع

|الحقل           |النوع المقترح|القيود/الملاحظات                |
|----------------|-------------|--------------------------------|
|`opportunity_id`|UUID         |FK → `training_opportunities.id`|
|`site_id`       |UUID         |FK → `training_sites.id`        |
|`college_id`    |UUID         |FK → `colleges.id`              |

المفتاح: (opportunity_id, site_id). الموقع الجديد لا يستخدم لتسجيل حضور حتى approval_status = approved. يحتفظ النظام بموقع معتمد تاريخيًا حتى لا تنكسر سجلات الحضور عند إيقاف عرضه لاحقًا؛ سياسة التعديل/الحذف تحتاج قرارًا.

2.2.11 training_applications — طلبات التدريب

|الحقل                     |النوع المقترح|القيود/الملاحظات                                                                                                                                                                    |
|--------------------------|-------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|`id`                      |UUID         |PK                                                                                                                                                                                  |
|`college_id`              |UUID         |FK → `colleges.id`, NOT NULL                                                                                                                                                        |
|`opportunity_id`          |UUID         |FK → `training_opportunities.id`, NOT NULL                                                                                                                                          |
|`student_user_id`         |UUID         |FK → `users.id`, NOT NULL                                                                                                                                                           |
|`student_message`         |TEXT         |nullable؛ رسالة قصيرة اختيارية                                                                                                                                                      |
|`resume_file_id`          |UUID         |FK → `file_assets.id`, nullable؛ PDF اختياري                                                                                                                                        |
|`status`                  |TEXT/ENUM    |`draft`, `submitted_company_review`, `company_rejected`, `college_review`, `approved`, `college_rejected`, `cancelled_by_student`؛ يجب مواءمة أسماء الحالات المعروضة مع واجهة الـPRD|
|`company_decided_by`      |UUID         |FK → `users.id`, nullable                                                                                                                                                           |
|`company_decided_at`      |TIMESTAMPTZ  |nullable                                                                                                                                                                            |
|`company_rejection_reason`|TEXT         |nullable                                                                                                                                                                            |
|`college_decided_by`      |UUID         |FK → `users.id`, nullable                                                                                                                                                           |
|`college_decided_at`      |TIMESTAMPTZ  |nullable                                                                                                                                                                            |
|`college_rejection_reason`|TEXT         |nullable                                                                                                                                                                            |
|`submitted_at`            |TIMESTAMPTZ  |nullable حتى الإرسال                                                                                                                                                                |
|`created_at`              |TIMESTAMPTZ  |مطلوب                                                                                                                                                                               |
|`updated_at`              |TIMESTAMPTZ  |مطلوب                                                                                                                                                                               |

قيد العمل: لا يزيد عدد طلبات الطالب النشطة على واحد؛ المسودة والطلب المرسل قيد المراجعة يدخلان تعريف «النشط» وفق تفسير المنتج. يجب تطبيق قيد فريد جزئي أو معاملة متسقة في الخادم. يحجز المقعد عند اعتماد مسؤول الكلية النهائي فقط (حالة الطلب approved)؛ الطلبات المنتظرة أو المرفوضة لا تدخل في عدد المقاعد المحجوزة. يجب تنفيذ التحقق والحجز داخل معاملة ذرية لمنع تجاوز السعة عند الاعتماد المتزامن. حالة إعادة التقديم على الفرصة نفسها تحتاج مواءمة مع PRD.

2.2.12 application_status_history — سجل انتقالات الطلب

|الحقل               |النوع المقترح|القيود/الملاحظات                           |
|--------------------|-------------|-------------------------------------------|
|`id`                |UUID         |PK                                         |
|`college_id`        |UUID         |FK → `colleges.id`, NOT NULL               |
|`application_id`    |UUID         |FK → `training_applications.id`, NOT NULL  |
|`from_status`       |TEXT         |nullable للحالة الأولى                     |
|`to_status`         |TEXT         |NOT NULL                                   |
|`changed_by_user_id`|UUID         |FK → `users.id`, nullable للعمليات النظامية|
|`reason`            |TEXT         |nullable                                   |
|`changed_at`        |TIMESTAMPTZ  |NOT NULL                                   |

يخدم هذا الجدول الخط الزمني المطلوب، ويُعامل كسجل إلحاقي لا يُحرر بعد التسجيل.

2.2.13 trainings — التدريب الفعلي

|الحقل                        |النوع المقترح|القيود/الملاحظات                                                                                           |
|-----------------------------|-------------|-----------------------------------------------------------------------------------------------------------|
|`id`                         |UUID         |PK                                                                                                         |
|`college_id`                 |UUID         |FK → `colleges.id`, NOT NULL                                                                               |
|`application_id`             |UUID         |FK → `training_applications.id`, UNIQUE؛ تدريب واحد كحد أقصى لكل طلب معتمد                                 |
|`student_user_id`            |UUID         |FK → `users.id`, NOT NULL                                                                                  |
|`opportunity_id`             |UUID         |FK → `training_opportunities.id`, NOT NULL                                                                 |
|`specialty_id`               |UUID         |FK → `specialties.id`, NOT NULL؛ نسخة التخصص وقت الاعتماد                                                  |
|`academic_supervisor_user_id`|UUID         |FK → `users.id`, NOT NULL بعد تعيين المشرف                                                                 |
|`start_date`                 |DATE         |تاريخ بداية التدريب الفعلي؛ هل يساوي تاريخ الفرصة أم قد يتغير؟ غير محسوم                                   |
|`end_date`                   |DATE         |تاريخ النهاية المتوقع/الفعلي؛ يلزم التفريق بينهما في التنفيذ                                               |
|`status`                     |TEXT/ENUM    |مقترح: `active`, `completed`, `ended_early`, `awaiting_evaluation`; تثبيت الحالات النهائية غير محسوم في PRD|
|`ended_at`                   |TIMESTAMPTZ  |nullable                                                                                                   |
|`ended_by_user_id`           |UUID         |FK → `users.id`, nullable                                                                                  |
|`end_request_id`             |UUID         |FK → `official_requests.id`, nullable                                                                      |
|`created_at`                 |TIMESTAMPTZ  |مطلوب                                                                                                      |
|`updated_at`                 |TIMESTAMPTZ  |مطلوب                                                                                                      |

العلاقات: تدريب واحد مرتبط بطالب وفرصة وطلب معتمد ومشرف، وله حضور وملاحظات وتقييم ومحادثات وبلاغات/طلبات رسمية. الكلية مسؤولة عن متابعة التدريب وإنهائه وفق القواعد.

2.2.14 training_supervisor_assignments — تاريخ إسناد المشرفين

|الحقل                |النوع المقترح|القيود/الملاحظات                                              |
|---------------------|-------------|--------------------------------------------------------------|
|`id`                 |UUID         |PK                                                            |
|`college_id`         |UUID         |FK → `colleges.id`, NOT NULL                                  |
|`training_id`        |UUID         |FK → `trainings.id`, NOT NULL                                 |
|`supervisor_user_id` |UUID         |FK → `users.id`, NOT NULL                                     |
|`assigned_by_user_id`|UUID         |FK → `users.id`, NOT NULL                                     |
|`start_at`           |TIMESTAMPTZ  |NOT NULL                                                      |
|`end_at`             |TIMESTAMPTZ  |nullable للمشرف الحالي                                        |
|`change_request_id`  |UUID         |FK → `official_requests.id` أو جدول طلب تغيير مستقل؛ غير محسوم|

يمنع أكثر من إسناد مفتوح لتدريب واحد. يسمح للمشرف بمتابعة تدريبات متعددة.

2.2.15 attendance_records — سجلات الحضور اليومية

|الحقل                                       |النوع المقترح|القيود/الملاحظات                                                                                                  |
|--------------------------------------------|-------------|------------------------------------------------------------------------------------------------------------------|
|`id`                                        |UUID         |PK                                                                                                                |
|`college_id`                                |UUID         |FK → `colleges.id`, NOT NULL                                                                                      |
|`training_id`                               |UUID         |FK → `trainings.id`, NOT NULL                                                                                     |
|`attendance_date`                           |DATE         |يوم التدريب المحلي للكلية                                                                                         |
|`check_in_at`                               |TIMESTAMPTZ  |nullable إذا لم يسجل الدخول                                                                                       |
|`check_in_latitude` / `check_in_longitude`  |NUMERIC(9,6) |nullable؛ إحداثية التسجيل                                                                                         |
|`check_in_accuracy_meters`                  |NUMERIC(7,2) |nullable؛ دقة الموقع المبلغ عنها                                                                                  |
|`check_in_site_id`                          |UUID         |FK → `training_sites.id`, nullable                                                                                |
|`check_out_at`                              |TIMESTAMPTZ  |nullable حتى الانصراف                                                                                             |
|`check_out_latitude` / `check_out_longitude`|NUMERIC(9,6) |nullable                                                                                                          |
|`check_out_accuracy_meters`                 |NUMERIC(7,2) |nullable                                                                                                          |
|`check_out_site_id`                         |UUID         |FK → `training_sites.id`, nullable                                                                                |
|`status`                                    |TEXT/ENUM    |`incomplete`, `pending_company_approval`, `approved`, `rejected`, `exception_pending`؛ القيم النهائية تحتاج تثبيتًا|
|`is_holiday_work`                           |BOOLEAN      |مطلوب؛ يوسم يوم العمل الاستثنائي                                                                                  |
|`company_reviewed_by`                       |UUID         |FK → `users.id`, nullable                                                                                         |
|`company_reviewed_at`                       |TIMESTAMPTZ  |nullable                                                                                                          |
|`rejection_reason`                          |TEXT         |nullable                                                                                                          |
|`approved_minutes`                          |INTEGER      |مشتق من الحضور والانصراف المعتمدين ومحدود بالحد اليومي للتخصص؛ يمكن تخزينه Snapshot مع حفظ المدخلات               |
|`created_at`                                |TIMESTAMPTZ  |مطلوب                                                                                                             |
|`updated_at`                                |TIMESTAMPTZ  |مطلوب                                                                                                             |

قواعد الحساب المنقولة من PRD: لا تخصم الاستراحات؛ اليوم = الانصراف − الحضور؛ حد أعلى يومي حسب التخصص؛ لا تحتسب الساعات قبل اعتماد مسؤول الشركة؛ سجل دون انصراف incomplete ولا يحتسب حتى التصحيح والاعتماد. لا تدمج سجلات متعددة في اليوم قبل اعتماد قاعدة التعدد.

2.2.16 attendance_change_requests — طلبات تصحيح/استثناء الحضور

|الحقل                   |النوع المقترح|القيود/الملاحظات                                                                                                   |
|------------------------|-------------|-------------------------------------------------------------------------------------------------------------------|
|`id`                    |UUID         |PK                                                                                                                 |
|`college_id`            |UUID         |FK → `colleges.id`, NOT NULL                                                                                       |
|`attendance_record_id`  |UUID         |FK → `attendance_records.id`, nullable عند طلب استثناء قبل إنشاء سجل حضور                                          |
|`training_id`           |UUID         |FK → `trainings.id`, NOT NULL                                                                                      |
|`student_user_id`       |UUID         |FK → `users.id`, NOT NULL                                                                                          |
|`request_type`          |TEXT/ENUM    |`correction`, `gps_exception`, `connectivity_exception`, `forgot_check_in`, `forgot_check_out`؛ مجموعة القيم مبدئية|
|`requested_check_in_at` |TIMESTAMPTZ  |nullable                                                                                                           |
|`requested_check_out_at`|TIMESTAMPTZ  |nullable                                                                                                           |
|`reason`                |TEXT         |NOT NULL                                                                                                           |
|`status`                |TEXT/ENUM    |`pending_company_review`, `approved`, `rejected`                                                                   |
|`decided_by_user_id`    |UUID         |FK → `users.id`, nullable؛ مسؤول جهة التدريب                                                                       |
|`decided_at`            |TIMESTAMPTZ  |nullable                                                                                                           |
|`decision_reason`       |TEXT         |nullable                                                                                                           |
|`created_at`            |TIMESTAMPTZ  |مطلوب                                                                                                              |

العلاقات: طلب واحد يتبع سجل حضور/تدريبًا ويصدر من الطالب، ويراجعه مسؤول الشركة. لا تكتسب الساعات صفة الاعتماد قبل قرار الشركة.

2.2.17 supervisor_notes — ملاحظات المشرف

|الحقل                      |النوع المقترح|القيود/الملاحظات                       |
|---------------------------|-------------|---------------------------------------|
|`id`                       |UUID         |PK                                     |
|`college_id`               |UUID         |FK → `colleges.id`, NOT NULL           |
|`training_id`              |UUID         |FK → `trainings.id`, NOT NULL          |
|`author_supervisor_user_id`|UUID         |FK → `users.id`, NOT NULL              |
|`note_text`                |TEXT         |NOT NULL                               |
|`created_at`               |TIMESTAMPTZ  |مطلوب                                  |
|`updated_at`               |TIMESTAMPTZ  |مطلوب؛ التعديل للمشرف الكاتب فقط مبدئيًا|

2.2.18 supervisor_note_revisions — سجل تغييرات الملاحظات

|الحقل               |النوع المقترح|القيود/الملاحظات                               |
|--------------------|-------------|-----------------------------------------------|
|`id`                |UUID         |PK                                             |
|`college_id`        |UUID         |FK → `colleges.id`, NOT NULL                   |
|`note_id`           |UUID         |FK → `supervisor_notes.id`, NOT NULL           |
|`changed_by_user_id`|UUID         |FK → `users.id`, NOT NULL؛ المشرف كاتب الملاحظة|
|`previous_text`     |TEXT         |nullable عند إنشاء النسخة الأولى               |
|`new_text`          |TEXT         |NOT NULL                                       |
|`changed_at`        |TIMESTAMPTZ  |NOT NULL                                       |

الوصول: المشرف المرتبط ومسؤول الكلية للقراءة فقط. يستطيع المشرف إنشاء/تعديل ملاحظاته؛ لا يستطيع المسؤول تعديلها. لا تظهر للطالب أو جهة التدريب.

2.2.19 final_evaluations — التقييم النهائي

|الحقل                 |النوع المقترح|القيود/الملاحظات                                                                      |
|----------------------|-------------|--------------------------------------------------------------------------------------|
|`id`                  |UUID         |PK                                                                                    |
|`college_id`          |UUID         |FK → `colleges.id`, NOT NULL                                                          |
|`training_id`         |UUID         |FK → `trainings.id`, UNIQUE؛ تقييم نهائي واحد لكل تدريب                               |
|`submitted_by_user_id`|UUID         |FK → `users.id`, NOT NULL؛ مسؤول الشركة                                               |
|`general_comment`     |TEXT         |nullable                                                                              |
|`status`              |TEXT/ENUM    |`draft`, `submitted`؛ التقييم يقدم مرة واحدة، حالة المسودة/التعديل تحتاج سياسة تفصيلية|
|`submitted_at`        |TIMESTAMPTZ  |nullable حتى الإرسال                                                                  |
|`created_at`          |TIMESTAMPTZ  |مطلوب                                                                                 |
|`updated_at`          |TIMESTAMPTZ  |مطلوب                                                                                 |

2.2.20 evaluation_criteria — معايير التقييم

|الحقل          |النوع المقترح|القيود/الملاحظات           |
|---------------|-------------|---------------------------|
|`id`           |SMALLINT/UUID|PK                         |
|`code`         |TEXT         |فريد وثابت                 |
|`name_ar`      |TEXT         |أحد المعايير الستة المعتمدة|
|`display_order`|SMALLINT     |ترتيب العرض                |
|`is_active`    |BOOLEAN      |مطلوب                      |

المعايير: الالتزام والانضباط، جودة العمل، المهارات المهنية، العمل الجماعي، تحقيق أهداف التدريب، المبادرة والابتكار.

2.2.21 evaluation_items — تقديرات معايير التقييم

|الحقل          |النوع المقترح|القيود/الملاحظات                                     |
|---------------|-------------|-----------------------------------------------------|
|`evaluation_id`|UUID         |FK → `final_evaluations.id`                          |
|`criterion_id` |SMALLINT/UUID|FK → `evaluation_criteria.id`                        |
|`rating`       |TEXT/ENUM    |`excellent`, `very_good`, `good`, `needs_improvement`|
|`comment`      |TEXT         |إلزامي إذا كان التقدير `needs_improvement`           |

المفتاح: (evaluation_id, criterion_id). يجب أن يحتوي التقييم المرسل على تقييم لكل معيار، وفق النموذج الشامل.

2.2.22 conversations — المحادثات

|الحقل        |النوع المقترح|القيود/الملاحظات                              |
|-------------|-------------|----------------------------------------------|
|`id`         |UUID         |PK                                            |
|`college_id` |UUID         |FK → `colleges.id`, NOT NULL                  |
|`training_id`|UUID         |FK → `trainings.id`, NOT NULL                 |
|`created_at` |TIMESTAMPTZ  |مطلوب                                         |
|`status`     |TEXT/ENUM    |مقترح `open`, `closed`; قرار الإغلاق غير محسوم|

2.2.23 conversation_participants — أطراف المحادثة

|الحقل            |النوع المقترح|القيود/الملاحظات       |
|-----------------|-------------|-----------------------|
|`conversation_id`|UUID         |FK → `conversations.id`|
|`user_id`        |UUID         |FK → `users.id`        |
|`college_id`     |UUID         |FK → `colleges.id`     |
|`joined_at`      |TIMESTAMPTZ  |مطلوب                  |

قيد: مشاركان بالضبط لكل محادثة في الـMVP، وكلاهما طرف مخول ومرتبط بالتدريب نفسه. يمكن أن يكونا أي طرفين من أطراف التدريب وفق الدور. منع المحادثة الجماعية مطلب محسوم؛ آلية إنشاء محادثة منفصلة لكل زوج لم تحددها PRD.

2.2.24 messages — الرسائل

|الحقل            |النوع المقترح|القيود/الملاحظات                             |
|-----------------|-------------|---------------------------------------------|
|`id`             |UUID         |PK                                           |
|`college_id`     |UUID         |FK → `colleges.id`, NOT NULL                 |
|`conversation_id`|UUID         |FK → `conversations.id`, NOT NULL            |
|`sender_user_id` |UUID         |FK → `users.id`, NOT NULL؛ يجب أن يكون مشاركًا|
|`body_text`      |TEXT         |NOT NULL؛ نص فقط، دون مرفقات                 |
|`sent_at`        |TIMESTAMPTZ  |NOT NULL                                     |
|`read_at`        |TIMESTAMPTZ  |nullable؛ إيصال القراءة لم يُحسم في PRD       |

2.2.25 dispute_reports — بلاغات النزاع

|الحقل                |النوع المقترح|القيود/الملاحظات                                                                     |
|---------------------|-------------|-------------------------------------------------------------------------------------|
|`id`                 |UUID         |PK                                                                                   |
|`college_id`         |UUID         |FK → `colleges.id`, NOT NULL                                                         |
|`training_id`        |UUID         |FK → `trainings.id`, NOT NULL                                                        |
|`reported_by_user_id`|UUID         |FK → `users.id`, NOT NULL؛ أحد أطراف التدريب                                         |
|`issue_description`  |TEXT         |NOT NULL؛ بلاغ مكتوب يوضح المشكلة                                                    |
|`status`             |TEXT/ENUM    |مقترح: `open`, `under_review`, `resolved`, `closed`؛ حالات القرار التفصيلية غير محددة|
|`college_decision_by`|UUID         |FK → `users.id`, nullable                                                            |
|`college_decision`   |TEXT         |nullable                                                                             |
|`college_decided_at` |TIMESTAMPTZ  |nullable                                                                             |
|`created_at`         |TIMESTAMPTZ  |مطلوب                                                                                |
|`updated_at`         |TIMESTAMPTZ  |مطلوب                                                                                |

الغرض الأمني: البلاغ القائم هو أحد الأسس المسموح بها لطلب مسؤول الكلية الاطلاع الاستثنائي على محادثة مرتبطة، وفق سياسة الوصول والتدقيق.

2.2.26 official_requests — الطلبات الرسمية

|الحقل               |النوع المقترح|القيود/الملاحظات                                                                                                             |
|--------------------|-------------|-----------------------------------------------------------------------------------------------------------------------------|
|`id`                |UUID         |PK                                                                                                                           |
|`college_id`        |UUID         |FK → `colleges.id`, NOT NULL                                                                                                 |
|`training_id`       |UUID         |FK → `trainings.id`, NOT NULL                                                                                                |
|`requester_user_id` |UUID         |FK → `users.id`, NOT NULL؛ طالب أو مسؤول جهة التدريب وفق نوع الطلب                                                           |
|`request_type`      |TEXT/ENUM    |مبدئيًا: `early_termination`, `supervisor_change`, `conversation_access` أو أنواع أخرى؛ يلزم ضبط اتساق الأنواع المسموحة مع PRD|
|`reason`            |TEXT         |NOT NULL                                                                                                                     |
|`status`            |TEXT/ENUM    |`submitted`, `under_review`, `approved`, `rejected`؛ دورة الحالات تحتاج اعتمادًا                                              |
|`decided_by_user_id`|UUID         |FK → `users.id`, nullable؛ مسؤول الكلية                                                                                      |
|`decision`          |TEXT         |nullable                                                                                                                     |
|`decided_at`        |TIMESTAMPTZ  |nullable                                                                                                                     |
|`created_at`        |TIMESTAMPTZ  |مطلوب                                                                                                                        |
|`updated_at`        |TIMESTAMPTZ  |مطلوب                                                                                                                        |

تعريف «الطلب الرسمي» الحاكم موجود مرة واحدة في قاعدة العمل 21 من الـPRD. مرفقات الطلب الاختيارية تحفظ في file_assets وترتبط بالطلب.

2.2.27 file_assets — بيانات الملفات

|الحقل                |النوع المقترح|القيود/الملاحظات                                 |
|---------------------|-------------|-------------------------------------------------|
|`id`                 |UUID         |PK                                               |
|`college_id`         |UUID         |FK → `colleges.id`, NOT NULL                     |
|`uploaded_by_user_id`|UUID         |FK → `users.id`, NOT NULL                        |
|`storage_key`        |TEXT         |NOT NULL؛ مرجع خاص إلى التخزين، لا رابط عام مكشوف|
|`original_filename`  |TEXT         |مطلوب                                            |
|`mime_type`          |TEXT         |مطلوب؛ يجب أن يكون PDF للسيرة الذاتية وفق PRD    |
|`size_bytes`         |BIGINT       |مطلوب                                            |
|`sha256`             |TEXT         |مقترح لفحص سلامة/تكرار الملف                     |
|`created_at`         |TIMESTAMPTZ  |مطلوب                                            |

الربط: يمكن أن يشير training_applications.resume_file_id إلى هذا الجدول. للطلبات الرسمية يمكن استخدام جدول ربط official_request_files(request_id, file_id, college_id) بمفتاح مركب. التخزين الخاص وفحص الملفات متطلبان تنفيذيان مقترحان، وسياسة أنواع/أحجام ملفات الطلب الرسمي غير محددة.

2.2.28 notifications — الإشعارات

|الحقل                |النوع المقترح|القيود/الملاحظات                           |
|---------------------|-------------|-------------------------------------------|
|`id`                 |UUID         |PK                                         |
|`college_id`         |UUID         |FK → `colleges.id`, NOT NULL               |
|`recipient_user_id`  |UUID         |FK → `users.id`, NOT NULL                  |
|`event_type`         |TEXT         |نوع الحدث                                  |
|`title_ar`           |TEXT         |عنوان عربي                                 |
|`body_ar`            |TEXT         |نص عربي                                    |
|`related_entity_type`|TEXT         |نوع السجل المرتبط، إن وجد                  |
|`related_entity_id`  |UUID         |معرّف السجل المرتبط، nullable               |
|`in_app_created_at`  |TIMESTAMPTZ  |nullable                                   |
|`email_status`       |TEXT/ENUM    |`not_required`, `pending`, `sent`, `failed`|
|`email_sent_at`      |TIMESTAMPTZ  |nullable                                   |
|`read_at`            |TIMESTAMPTZ  |nullable                                   |
|`created_at`         |TIMESTAMPTZ  |مطلوب                                      |

تحدد سياسة إرسال البريد ومستلمو كل حدث بالرجوع إلى قسم الإشعارات في PRD؛ الجداول لا تمنح الإشعار صلاحيات على السجل الأصلي.

2.2.29 audit_logs — سجل التدقيق

|الحقل          |النوع المقترح|القيود/الملاحظات                                                 |
|---------------|-------------|-----------------------------------------------------------------|
|`id`           |UUID         |PK                                                               |
|`college_id`   |UUID         |FK → `colleges.id`, nullable لحدث مركزي للمسؤول الأعلى فقط       |
|`actor_user_id`|UUID         |FK → `users.id`, nullable لعملية نظامية                          |
|`action`       |TEXT         |نوع العملية                                                      |
|`entity_type`  |TEXT         |نوع السجل المتأثر                                                |
|`entity_id`    |UUID         |معرّف السجل، nullable                                             |
|`reason`       |TEXT         |مطلوب عند الاطلاع الاستثنائي؛ nullable لغيره بحسب نوع الحدث      |
|`metadata`     |JSONB        |تفاصيل دنيا لازمة للتدقيق، مع منع نسخ محتوى محادثة/موقع غير مطلوب|
|`occurred_at`  |TIMESTAMPTZ  |NOT NULL                                                         |

قيود: سجل إلحاقي لا يعدل ولا يحذف من واجهات التشغيل العادية. يجب إنشاء حدث تدقيق لكل اطلاع استثنائي على محادثة، يتضمن المسؤول والوقت والسبب، ولكل تعديل ملاحظة في supervisor_note_revisions. مدة الاحتفاظ وقراءة السجل وصلاحية تصديره تحتاج تحديدًا.

2.3 العلاقات الرئيسية (مختصر)

• colleges 1—N users, specialties, training_opportunities, training_sites, trainings.
• users N—N roles عبر user_roles.
• specialties 1—1 specialty_training_requirements، وspecialties N—N training_opportunities عبر opportunity_specialties.
• training_opportunities N—N training_sites عبر opportunity_sites.
• users (student) 1—N training_applications; الفرصة 1—N الطلبات. قيد طلب واحد نشط للطالب.
• training_applications 1—0..1 trainings; التدريب يتبع طالبًا ومشرفًا وفرصة واحدة.
• trainings 1—N attendance_records, supervisor_notes, conversations, dispute_reports, official_requests; trainings 1—0..1 final_evaluations.
• attendance_records 1—N attendance_change_requests (قد تكون صفرًا أو أكثر، إلى أن تُحسم قاعدة التكرار).
• supervisor_notes 1—N supervisor_note_revisions.
• final_evaluations 1—N evaluation_items.
• conversations 1—2 conversation_participants وconversations 1—N messages.
• users 1—N notifications, audit_logs كفاعل أو متلقٍ.

2.4 عزل بيانات الكليات (college_id)

قواعد العزل

1. تحديد نطاق المستخدم: كل مستخدم غير المسؤول الأعلى مرتبط بـcollege_id واحد في التصميم الأولي. يؤخذ النطاق من جلسة المصادقة/هوية المستخدم الموثقة، ولا يقبل من قيمة يرسلها المتصفح وحدها.
2. إلزام النطاق في الاستعلام: كل قراءة/كتابة على جدول كلية تتضمن قيد college_id = current_user.college_id، ويعاد التحقق من النطاق في كل علاقة فرعية.
3. منع التناقض العابر للكليات: عند كتابة training_id أو opportunity_id أو user_id في سجل تابع، يتحقق الخادم أن جميع السجلات المرتبطة من الكلية نفسها. يفضل استخدام مفاتيح فريدة مركبة مثل (college_id, id) ومفاتيح أجنبية مركبة في الجداول متعددة النطاق لمنع ربط سجل من كلية بسجل من كلية أخرى.
4. عزل على مستوى قاعدة البيانات: PostgreSQL مع RLS قرار معتمد. تُطبق سياسات RLS على كل جدول نطاقي، مع سياق كلية مضبوط من الخادم. لا تكون هوية مسؤول النظام الأعلى سببًا لتجاوز RLS تلقائيًا؛ وصوله يقتصر على إدارة الكليات وفق الصلاحيات المحددة، وأي استثناء يجب أن يكون محددًا ومدققًا.
5. ملفات التخزين: تحفظ الملفات في مساحة/مسار خاص متضمنًا معرف الكلية، وتصدر عبر روابط قصيرة الصلاحية بعد تحقق الإذن. لا تستخدم روابط عامة ثابتة.
6. الفهارس: تبدأ الفهارس المركبة بـcollege_id للاستعلامات متعددة النطاق، مثل (college_id, status) أو (college_id, training_id, created_at).
7. المسؤول الأعلى: إضافة كلية وإدارة بيانات تعريفها فقط وفق الـPRD؛ لا وصول افتراضي لسجلات التدريب أو المحادثات أو التقييمات. أية صلاحية إدارية استثنائية غير موصوفة يجب أن تخضع لتدقيق وموافقة سياسة لاحقة.

أمثلة قيود التحقق

• لا يجوز لطلب في college_id = A أن يشير إلى طالب أو فرصة في كلية B.
• لا يجوز لمحادثة تخص تدريبًا في كلية A أن تضم مستخدمًا لا يملك صفة طرف مرتبط بذلك التدريب.
• لا يجوز لموقع معتمد في كلية A أن يستخدمه تدريب تابع لكلية B.
• لا يجوز لمسؤول شركة من كلية أخرى الاطلاع على سيرة ذاتية أو تقييم أو سجل حضور.

3. مصفوفة الصلاحيات

مفاتيح القراءة

• —: لا وصول.
• قراءة: قراءة ضمن السجلات التي يرتبط بها المستخدم ونطاق كليته.
• إنشاء/تعديل: بحسب سير العمل المحدد في الـPRD، دون تجاوز اعتماد الطرف المخول.
• مقيد: لا يسمح إلا بتحقق الشرط المذكور في خلية الصلاحية وسجل التدقيق عند اللزوم.
• المسؤول الأعلى لا يرى بيانات الجداول التشغيلية تلقائيًا. «المالك/الأطراف» تعني المستخدم المرتبط بالسجل وفق التدريب/الفرصة.

|الجدول                                   |الطالب                                                                  |المشرف الأكاديمي                                                       |مسؤول جهة التدريب                                                                   |مسؤول الكلية                                                                                       |المسؤول الأعلى                                                                 |
|-----------------------------------------|------------------------------------------------------------------------|-----------------------------------------------------------------------|------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
|`colleges`                               |قراءة اسم كليته                                                         |قراءة اسم كليته                                                        |قراءة اسم كليته                                                                     |قراءة/إدارة إعدادات كليته                                                                          |إنشاء/إدارة سجل الكلية فقط                                                     |
|`users`                                  |قراءة/تعديل بيانات حسابه الأساسية                                       |قراءة بيانات الأطراف المرتبطة؛ تعديل حسابه                             |قراءة بيانات الأطراف المرتبطة؛ تعديل حسابه                                          |قراءة مستخدمي كليته؛ الموافقة على التفعيل وإدارة حالة الحساب ضمن ما يحدده PRD                      |إدارة بيانات الكليات؛ لا وصول افتراضي لبيانات الحساب التشغيلية                 |
|`roles`, `user_roles`                    |لا وصول إداري؛ يرى دوره                                                 |لا وصول إداري؛ يرى دوره                                                |لا وصول إداري؛ يرى دوره                                                             |قراءة الأدوار والإسناد ضمن الكلية؛ الموافقة/تفعيل الأدوار                                          |إدارة تعريفات الأدوار المركزية فقط إذا اعتمد ذلك؛ خارج نطاق صلاحيات PRD الحالية|
|`specialties`                            |قراءة تخصصات كليته واختيار تخصصه                                        |قراءة تخصصات كليته                                                     |قراءة ما يلزم للفرص                                                                 |إنشاء/تعديل/تعطيل تخصصات كليته                                                                     |—                                                                              |
|`specialty_training_requirements`        |قراءة متطلبات تخصصه                                                     |قراءة متطلبات التخصصات المرتبطة بالطلاب                                |—                                                                                   |إنشاء/تعديل متطلبات كليته                                                                          |—                                                                              |
|`training_opportunities`                 |قراءة الفرص المفتوحة المطابقة لكليته وتخصصه فقط                         |قراءة فرص تدريبات الطلاب المسندين                                      |إنشاء/قراءة/تعديل فرصه وإغلاقها/تحديد المقاعد                                       |قراءة للمتابعة والاعتماد، دون تعديل بيانات التدريب اعتياديًا                                        |—                                                                              |
|`opportunity_specialties`                |قراءة التخصصات المستهدفة في الفرصة المعروضة                             |قراءة ما يتعلق بطلاب الإشراف                                           |إنشاء/تعديل ارتباطات فرصه                                                           |قراءة للتحقق من المطابقة                                                                           |—                                                                              |
|`training_sites`                         |قراءة المواقع المعتمدة ذات الصلة؛ لا قراءة إدارية للبيانات غير اللازمة  |قراءة المواقع ذات الصلة بالتدريب                                       |إنشاء/تعديل مواقع جهته قبل/بعد الموافقة بحسب السياسة؛ لا يجعلها مستخدمة قبل الاعتماد|قراءة/اعتماد أو رفض موقع جديد؛ تعديل نصف قطر القبول                                                |—                                                                              |
|`opportunity_sites`                      |قراءة المواقع المعتمدة للفرص المعروضة                                   |قراءة مواقع تدريبات طلابه                                              |ربط مواقع بفرصه                                                                     |قراءة/مراجعة الارتباط                                                                              |—                                                                              |
|`training_applications`                  |إنشاء/قراءة/تعديل مسودته؛ سحب طلبه قبل الاعتماد النهائي؛ قراءة حالة طلبه|قراءة طلبات تدريبات طلابه بعد الإسناد                                  |قراءة طلبات الفرص التابعة له واتخاذ قرار الشركة مع السبب                            |قراءة الطلبات وموافقة/رفض الكلية نهائيًا مع السبب                                                   |—                                                                              |
|`application_status_history`             |قراءة تاريخ طلبه                                                        |قراءة سجل الطلب المرتبط بطالب تحت إشرافه عند الحاجة                    |قراءة سجل طلبات فرصته                                                               |قراءة سجل كليته                                                                                    |—                                                                              |
|`trainings`                              |قراءة تدريبه وبياناته الأساسية                                          |قراءة تقدم تدريباته المسندة                                            |قراءة التدريب المرتبط بفرصته؛ طلب إنهاء رسمي                                        |قراءة/متابعة؛ إنهاء استثنائي بناءً على طلب رسمي؛ لا تعديل/إيقاف اعتيادي                             |—                                                                              |
|`training_supervisor_assignments`        |قراءة المشرف الحالي؛ إنشاء طلب تغيير لا تعديل الإسناد                   |قراءة إسناداته؛ لا يعدلها                                              |—                                                                                   |قراءة/إنشاء/إنهاء الإسناد عند الموافقة على التغيير                                                 |—                                                                              |
|`attendance_records`                     |إنشاء تسجيله؛ قراءة سجلاته؛ لا يعتمدها ولا يحرر السجل المعتمد مباشرة    |قراءة سجلات الطلاب المسندين إليه                                       |قراءة ومراجعة/اعتماد/رفض سجلات تدريب شركته يوميًا                                    |قراءة للمتابعة فقط                                                                                 |—                                                                              |
|`attendance_change_requests`             |إنشاء/قراءة طلباته وتقديم بيانات التصحيح                                |قراءة الطلبات المرتبطة بطلاب الإشراف عند الحاجة                        |قراءة/اعتماد/رفض طلبات التدريب التابع له                                            |قراءة للمتابعة؛ لا اعتماد بديل وفق PRD                                                             |—                                                                              |
|`supervisor_notes`                       |—                                                                       |إنشاء/قراءة/تعديل ملاحظاته لطلابه فقط                                  |—                                                                                   |**قراءة فقط** لملاحظات كليته                                                                       |—                                                                              |
|`supervisor_note_revisions`              |—                                                                       |قراءة سجل تغييرات ملاحظاته                                             |—                                                                                   |**قراءة فقط** لسجل تغييرات ملاحظات الكلية                                                          |—                                                                              |
|`final_evaluations`                      |قراءة التقييم النهائي لتدريبه بعد الإرسال                               |قراءة تقييم الطلاب المسندين                                            |إنشاء/إرسال تقييم تدريبه مرة واحدة؛ قراءة تقييمه المرسل وحالة استلامه فقط           |قراءة تقييمات كليته؛ تسجيل استثناء موثق عند تعذر التقييم                                           |—                                                                              |
|`evaluation_criteria`, `evaluation_items`|قراءة عناصر التقييم النهائي الخاص به                                    |قراءة عناصر تقييم الطالب المسند                                        |إنشاء عناصر تقييم التدريب؛ قراءة إرساله فقط                                         |قراءة عناصر التقييم                                                                                |—                                                                              |
|`conversations`                          |قراءة/بدء محادثات فردية إذا كان طرفًا في التدريب                         |قراءة/بدء محادثة فردية إذا كان طرفًا                                    |قراءة/بدء محادثة فردية إذا كان طرفًا                                                 |**لا وصول افتراضي**؛ قراءة استثنائية فقط ببلاغ نزاع أو طلب رسمي قائم، مع تسجيل السبب والهوية والوقت|— افتراضيًا؛ أي استثناء يحتاج سياسة مستقلة وتدقيقًا                              |
|`conversation_participants`              |قراءة عضوية محادثاته فقط                                                |قراءة عضوية محادثاته فقط                                               |قراءة عضوية محادثاته فقط                                                            |قراءة مقيدة بنفس شروط الاطلاع على المحادثة                                                         |—                                                                              |
|`messages`                               |قراءة/إرسال رسائل نصية في محادثاته                                      |قراءة/إرسال في محادثاته                                                |قراءة/إرسال في محادثاته                                                             |**قراءة مقيدة** فقط عند تحقق شرط الاطلاع الاستثنائي وتسجيله؛ لا إرسال باسم أحد الأطراف             |— افتراضيًا                                                                     |
|`dispute_reports`                        |إنشاء/قراءة بلاغاته                                                     |إنشاء/قراءة بلاغه إذا كان طرفًا                                         |إنشاء/قراءة بلاغه إذا كان طرفًا                                                      |قراءة/تسجيل القرار وإغلاقه وفق آلية لم تحسم بالكامل                                                |—                                                                              |
|`official_requests`                      |إنشاء/قراءة طلباته والقرار                                              |قراءة الطلب إذا كان طرفًا أو مرتبطًا بالتدريب حسب الحاجة                 |إنشاء/قراءة طلباته والقرار                                                          |قراءة ومراجعة/اعتماد/رفض، مع تسجيل القرار                                                          |—                                                                              |
|`file_assets`                            |رفع/قراءة ملفاته المسموح بها؛ قراءة CV الخاص بطلبه                      |— افتراضيًا؛ لا يظهر الملف إلا إذا كان جزءًا من تفويض قراءة الطلب المرتبط|رفع/قراءة مرفقات طلباته الرسمية ذات الصلة                                           |قراءة مرفقات الطلبات التي يراجعها؛ دون وصول عام                                                    |—                                                                              |
|`notifications`                          |قراءة/تحديث حالة قراءة إشعاراته                                         |قراءة/تحديث حالة قراءة إشعاراته                                        |قراءة/تحديث حالة قراءة إشعاراته                                                     |قراءة/تحديث إشعاراته                                                                               |—                                                                              |
|`audit_logs`                             |—                                                                       |—                                                                      |—                                                                                   |قراءة محدودة لأحداث كليته عند الحاجة الإدارية؛ الاطلاع الاستثنائي يسجل بذاته                       |قراءة أحداث إدارة الكليات فقط؛ صلاحية أحداث أخرى غير معتمدة                    |

3.1 ضوابط الاستثناءات

• المحادثات: الاطلاع الإداري ليس صلاحية عامة. يجب وجود بلاغ نزاع أو طلب رسمي قائم مرتبط بالتدريب والمحادثة، وإدخال سبب الوصول قبل إظهار الرسائل. يسجل حدث التدقيق هوية المسؤول والوقت والسبب ومعرف المحادثة/التدريب، لا محتوى الرسائل.
• ملاحظات المشرف: المشرف صاحب الملاحظة يضيفها ويعدلها؛ سجل النسخ يحفظ التغييرات. مسؤول الكلية يقرأ الملاحظات وسجلها فقط. لا يراها الطالب أو مسؤول جهة التدريب.
• مسؤول الشركة: لا يطلع على ملاحظات المشرف أو مداولات الكلية. في التقييم يرى التقييم الذي أرسله وحالة استلامه فقط.
• مسؤول الكلية: لا يعدل بيانات التدريب أو يوقفه كإجراء اعتيادي. يجوز له إنهاء التدريب بقرار موثق لأسباب مقبولة (مثل ظرف صحي أو إغلاق الجهة أو مخالفة جسيمة)، مع حفظ الساعات المعتمدة والسجل التاريخي، دون اعتبار الساعات تلقائيًا مستوفية للمتطلبات؛ ويحدد قرار إعادة التقديم ويوثقه. ويمكنه تسجيل استثناء موثق للإغلاق دون تقييم وفق ضوابط PRD-10.
• المسؤول الأعلى: إضافة الكليات وإدارة بياناتها الأساسية فقط؛ لا وصول افتراضي إلى الجداول التشغيلية.

4. شاشات الطالب الأساسية

4.1 مبادئ العرض العامة

• اتجاه الواجهة RTL؛ ترتيب التنقل، الحقول، الأيقونات، الأزرار، الخط الزمني، والرسائل يتبع العربية.
• تستخدم الواجهة تسميات واضحة للحالات: «مسودة»، «بانتظار رد جهة التدريب»، «بانتظار اعتماد الكلية»، «معتمد»، «مرفوض»، «ملغى»، «بانتظار اعتماد الحضور»، «غير مكتمل».
• لا تعتمد الواجهة على اللون وحده لبيان الحالة؛ تستخدم نصًا وأيقونة/علامة مناسبة.
• الرسائل التالية نصوص مقترحة للتصميم، وليست تغييرًا لقواعد الـPRD.
• لكل شاشة حالات تحميل وخطأ وبيانات فارغة حيثما ينطبق. رسائل الخطأ لا تدعي نجاح حفظ/إرسال قبل تأكيده من الخادم.

4.2 شاشة التسجيل

الغرض: تسجيل الطالب والتحقق من بريده ثم انتظار موافقة مسؤول الكلية.

العناصر:

• حقلا الاسم الأول والأخير إلزاميان، والبريد الإلكتروني، وكلمة المرور، وتأكيد كلمة المرور (التأكيد حقل واجهة مقترح)، واختيار الكلية من قائمة.
• الرقم الجامعي إلزامي للطالب.
• اختيار التخصص من قائمة تخصصات الكلية بعد اختيارها.
• ملاحظة الحد الأدنى لكلمة المرور: 8 خانات، ورابط «نسيت كلمة المرور؟» في مسار الدخول.
• زر «إنشاء الحساب» ورابط/إجراء إعادة إرسال رسالة التحقق.
• حالة واضحة بعد التحقق: الحساب بانتظار موافقة مسؤول الكلية.

الحالات والرسائل:

• تحميل: «جارٍ تحميل الكليات والتخصصات…».
• قائمة الكليات فارغة: «لا توجد كليات متاحة للتسجيل حاليًا. يُرجى المحاولة لاحقًا أو التواصل مع مسؤول النظام.»
• التخصصات فارغة: «لا توجد تخصصات متاحة لهذه الكلية حاليًا.»
• خطأ تحقق البريد/الإرسال: «تعذر إرسال رسالة التحقق. تحقق من اتصالك وحاول مرة أخرى.»
• بريد مستخدم أو بيانات غير صالحة: رسالة مرتبطة بالحقل، مثل «تحقق من صيغة البريد الإلكتروني»؛ لا يكشف النظام إن كان البريد لحساب قائم في مسارات استعادة كلمة المرور.
• نجاح التسجيل: «أُنشئ الحساب. أرسلنا رابط التحقق إلى بريدك الإلكتروني.»
• بعد التحقق: «تم التحقق من بريدك. حسابك الآن بانتظار موافقة مسؤول الكلية.»
• خطأ عام: «تعذر إنشاء الحساب الآن. لم تُرسل بياناتك؛ حاول مرة أخرى.» يحدد النص النهائي بحسب ما إذا كان الخادم حفظ الحساب أم لا.

ملاحظات/افتراضات: الاسم الأول والأخير والرقم الجامعي حقول إلزامية معتمدة لكل طالب. تأكيد كلمة المرور عنصر واجهة مقترح. طريقة تأكيد البريد، انتهاء صلاحية الرابط، وإعادة الإرسال لم تحدد.

4.3 شاشة تصفح الفرص

الغرض: عرض فرص مفتوحة للكلية والتخصص المطابقين فقط.

العناصر:

• قائمة بطاقات RTL لكل فرصة: العنوان، جهة التدريب، وصف مختصر للمهام، التخصصات المستهدفة، فترة البداية والنهاية، عدد المقاعد إذا تقرر عرضه، والمواقع/المدينة إذا كانت بياناتها متاحة.
• زر «عرض التفاصيل» ثم «التقديم على الفرصة».
• مرشحات/بحث اختياريان؛ غير مطلوبين صراحة في PRD، لذا لا يعدان شرطًا قبل قرار المنتج.
• لا تعرض الفرص المغلقة أو الممتلئة أو التي لا تستهدف تخصص الطالب أو كليته.

الحالات والرسائل:

• تحميل: «جارٍ تحميل فرص التدريب…» مع عناصر تحميل مؤقتة.
• لا توجد فرص: «لا توجد فرص مفتوحة مناسبة لتخصصك في الوقت الحالي.»
• خطأ: «تعذر تحميل الفرص. تحقق من اتصالك وحاول مرة أخرى.» مع «إعادة المحاولة».
• فرصة أُغلقت/امتلأت أثناء التصفح: عند فتحها أو محاولة التقديم، يعاد التحقق من الخادم وتظهر: «لم تعد هذه الفرصة متاحة للتقديم.» وتزال من القائمة بعد تحديثها.
• طلب نشط قائم: «لديك طلب تدريب نشط. ألغِه قبل التقديم على فرصة أخرى.» مع رابط إلى حالة الطلب، إذا كان الإلغاء لا يزال مسموحًا.

4.4 شاشة تفاصيل الفرصة والطلب/المسودة

الغرض: عرض تفاصيل الفرصة وجمع مدخلات الطلب، مع دعم الحفظ كمسودة والتعديل قبل الإرسال.

العناصر:

• بيانات الفرصة للقراءة: العنوان، وصف المهام، التخصصات المستهدفة، المواقع، تواريخ البداية والنهاية، حالة الفرصة، وسعة المقاعد إذا اختير عرضها.
• بيانات الطالب الأساسية للقراءة من الحساب؛ لا يكرر إدخالها في الطلب.
• حقل «رسالة قصيرة إلى جهة التدريب» اختياري.
• حقل رفع السيرة الذاتية اختياري، يقبل PDF فقط بحسب PRD؛ يعرض اسم الملف وحجمه/حذفه قبل الإرسال. الحد الأقصى للحجم غير محدد.
• زران: «حفظ كمسودة» و«إرسال الطلب». تأكيد إرسال الطلب قبل الإرسال النهائي مقترح UX، وليس شرطًا إضافيًا.
• عند المسودة: السماح بتعديلها. عند الإرسال لا تعرض شاشة المسودة كقابلة للتعديل إلا إذا كانت قواعد الحالة تسمح بذلك؛ صلاحية التعديل بعد الإرسال غير مقررة.

الحالات والرسائل:

• تحميل التفاصيل: «جارٍ تحميل تفاصيل الفرصة…».
• الفرصة غير متاحة: «هذه الفرصة مغلقة أو لم تعد تستقبل طلبات.»
• حفظ مسودة ناجح: «حُفظت المسودة. يمكنك العودة لتعديلها قبل الإرسال.»
• خطأ في حفظ المسودة: «تعذر حفظ المسودة. لم نؤكد حفظ التغييرات؛ حاول مرة أخرى.»
• رفع ملف غير PDF: «صيغة الملف غير مدعومة. ارفع السيرة الذاتية بصيغة PDF.»
• فشل رفع ملف/اتصال: «تعذر رفع الملف. تحقق من اتصالك وحاول مرة أخرى.»
• تجاوز سعة غير محددة: لا يعرض حد حجم حتى يحدد؛ يمكن عرض خطأ عام «تعذر رفع الملف» دون اختراع حد.
• إرسال ناجح: «تم إرسال طلبك إلى جهة التدريب.»
• فشل الإرسال: «لم يتم إرسال الطلب. تحقق من اتصالك ثم أعد المحاولة.»
• طلب نشط قائم أو امتلاء آخر مقعد بالتزامن: يمنع الخادم الإنشاء، ويعرض تفسيرًا بحسب السبب: «لديك طلب نشط بالفعل» أو «امتلأت مقاعد الفرصة».

4.5 شاشة تتبع حالة الطلب

الغرض: إظهار الحالة الحالية وسجل الانتقالات والإجراء المطلوب.

العناصر:

• اسم الفرصة وجهة التدريب ووقت تقديم الطلب.
• خط زمني RTL: «مسودة» ← «قُدّم الطلب/بانتظار رد جهة التدريب» ← «موافقة جهة التدريب/بانتظار اعتماد الكلية» ← «معتمد نهائيًا»، مع حالات نهاية منفصلة «مرفوض من جهة التدريب»، «مرفوض من الكلية»، «ملغى من الطالب».
• تاريخ كل انتقال، والسبب المسجل للرفض إن توفر.
• الإجراء التالي بوضوح، مثل «بانتظار قرار جهة التدريب» أو «بانتظار اعتماد الكلية».
• زر «إلغاء الطلب» فقط حين يكون الإلغاء مسموحًا وفق الـPRD وقبل الاعتماد النهائي.

الحالات والرسائل:

• تحميل: «جارٍ تحميل حالة الطلب…».
• لا يوجد طلب: «لا يوجد لديك طلب تدريب لعرضه.» مع رابط «تصفح الفرص».
• خطأ: «تعذر تحميل حالة الطلب. أعد المحاولة.»
• قيد المراجعة: «طلبك قيد المراجعة. سنُشعرك عند تحديث الحالة.»
• مرفوض مع سبب: «رُفض الطلب من [جهة التدريب/الكلية]. السبب: [السبب المسجل].»
• مرفوض دون سبب: «رُفض الطلب.» لا يُنشأ سبب افتراضي.
• ملغى: «ألغيت هذا الطلب.»
• معتمد: «اعتمد تدريبك نهائيًا. تابع تسجيل الحضور من شاشة التدريب.»
• فشل الإلغاء: «تعذر إلغاء الطلب أو لم يعد الإلغاء متاحًا. حدّث الحالة للتحقق.»

4.6 شاشة تسجيل الحضور

الغرض: تسجيل وقت الحضور والانصراف وموقع لحظة التسجيل، وإظهار الساعات المعتمدة.

العناصر:

• تاريخ اليوم بحسب توقيت الكلية (التوقيت يحتاج ضبطًا عند الإعداد).
• حالتا اليوم: «لم يسجل الحضور»، «بانتظار الانصراف»، «بانتظار اعتماد جهة التدريب»، «معتمد»، «غير مكتمل»، «يحتاج تصحيحًا/استثناءً».
• زر «تسجيل الحضور» أو «تسجيل الانصراف» حسب حالة سجل اليوم.
• معلومات الموقع المعتمد المرتبط بالفرصة، ونصف قطره المعتمد، ورسالة توضيحية أن الموقع يُطلب أثناء الاستخدام فقط.
• حالة GPS ودقته (إن أتاح الجهاز ذلك) قبل الإرسال؛ لا يعلن النظام اعتماد الحضور قبل مراجعة الشركة.
• مجموع الساعات المعتمدة في اليوم والتقدم تجاه الحد الأدنى، مع إظهار سقف ساعات اليوم حسب التخصص. لا تُخصم الاستراحات.
• رابط «طلب تصحيح أو استثناء» عند نسيان التسجيل أو فشل تحديد الموقع/الاتصال.

الحالات والرسائل:

• تحميل: «جارٍ تحميل سجل حضورك…».
• لا يوجد سجل اليوم: «لم تسجل حضورك اليوم بعد.»
• طلب إذن الموقع: «نحتاج إلى إذن الموقع أثناء الاستخدام للتحقق من موقع التدريب.» أزرار النظام الأصلية تمنح الإذن؛ لا يطلب التطبيق إذنًا دائمًا.
• الإذن مرفوض: «تعذر استخدام موقعك. يمكنك إعادة تفعيل إذن الموقع أو تقديم طلب استثناء.»
• GPS بدقة أفضل من أو تساوي عتبة 100 متر وداخل النطاق: «تم إرسال تسجيلك للمراجعة. سيعتمده مسؤول جهة التدريب.»
• الدقة أسوأ من 100 متر: «دقة الموقع غير كافية للتسجيل التلقائي. قدّم طلب استثناء لمراجعة مسؤول جهة التدريب.»
• خارج النطاق: «يبدو أنك خارج نطاق موقع التدريب المعتمد. يمكنك تقديم طلب استثناء.»
• موقع غير معتمد: «هذا الموقع غير معتمد بعد. اختر موقعًا معتمدًا أو قدّم طلب استثناء.»
• انقطاع الإنترنت قبل الإرسال: «لم يُرسل التسجيل. اتصل بالإنترنت ثم حاول مرة أخرى.» ولا يعرض كطلب مستلم.
• تم تسجيل حضور ولم يسجل انصراف: «سجل اليوم غير مكتمل؛ لا تُحتسب ساعاته حتى تقديم طلب تصحيح واعتماده.»
• تجاوز الحد اليومي: «احتُسبت ساعات اليوم حتى الحد اليومي المقرر لتخصصك.»
• تسجيل مكرر/حالة متزامنة: «يوجد تسجيل لهذا الوقت أو تغيّرت حالة السجل. حدّث الصفحة قبل المحاولة.» صياغة واجهة مقترحة؛ سياسة التكرار الدقيقة غير محددة.
• تحميل السجل فشل: «تعذر تحميل سجل الحضور. أعد المحاولة.»

4.7 شاشة طلب التصحيح/الاستثناء

الغرض: طلب تصحيح وقت منسي أو استثناء عند تعذر GPS/الاتصال، لمراجعة مسؤول جهة التدريب.

العناصر:

• نوع الطلب: تصحيح الحضور، تصحيح الانصراف، مشكلة GPS، مشكلة اتصال، أو سبب استثنائي آخر. خيارات النوع تمثيل واجهة مقترح للأنواع المقررة؛ القائمة النهائية تحتاج اعتمادًا.
• التاريخ وسجل الحضور المرتبط إن وجد.
• الوقت المطلوب للحضور و/أو الانصراف، حسب نوع التصحيح.
• حقل سبب إلزامي وفق متطلب السبب في طلبات التصحيح/الاستثناء في PRD.
• زر «إرسال للمراجعة» وزر «رجوع».
• حالة الطلب بعد الإرسال: «بانتظار مراجعة مسؤول جهة التدريب»، ثم «معتمد» أو «مرفوض»؛ وإظهار قرار الرفض/السبب عند إدخاله.

الحالات والرسائل:

• تحميل: «جارٍ تحميل بيانات اليوم…».
• لا يوجد سجل: يمكن بدء طلب استثناء مرتبط بالتدريب/اليوم، لكن السماح به من دون سجل مرتبط يحتاج تنفيذًا يطابق FR-29.
• نقص حقول: «أدخل الوقت المطلوب وسبب الطلب.»
• إرسال ناجح: «أُرسل طلبك إلى مسؤول جهة التدريب للمراجعة. لن تُحتسب الساعات قبل اعتماده.»
• فشل الإرسال/انقطاع الاتصال: «لم يُرسل طلب التصحيح. أعد المحاولة عند عودة الاتصال.»
• بانتظار القرار: «طلبك قيد المراجعة.»
• اعتماد: «تم اعتماد التصحيح. ستظهر الساعات بعد تحديث السجل.»
• رفض: «رُفض طلب التصحيح.» مع سبب الرفض إن سجله المسؤول.

4.8 شاشة عرض التقييم النهائي

الغرض: إتاحة التقييم النهائي للطالب بعد إرساله من مسؤول الشركة، كما تقرر في الـPRD.

العناصر:

• اسم التدريب وجهة التدريب وتاريخ إرسال التقييم.
• المعايير الستة، مع التقدير الوصفي لكل معيار: ممتاز، جيد جدًا، جيد، يحتاج تحسين.
• ملاحظات مسؤول الشركة على معيار «يحتاج تحسين» عند وجودها، والملاحظة العامة إن أضافها.
• عرض للقراءة فقط؛ لا يعدل الطالب تقييم مسؤول الشركة.
• حالة العرض/الإرسال إن كانت متاحة. تأكيد «تمت القراءة» غير محدد في الـPRD ولا يضاف كمتطلب.

الحالات والرسائل:

• تحميل: «جارٍ تحميل التقييم النهائي…».
• لم يرسل بعد: «لم يُرسل التقييم النهائي بعد. سيظهر هنا بعد إرساله من جهة التدريب.»
• تم الإرسال: عرض التقديرات والملاحظات المرسلة.
• إغلاق باستثناء: إذا أغلق مسؤول الكلية التدريب دون تقييم، تعرض رسالة محايدة: «أُغلق التدريب باستثناء موثق دون تقييم نهائي.» دون كشف تفاصيل داخلية غير مصرح بها.
• خطأ: «تعذر تحميل التقييم. أعد المحاولة.»
• لا يملك الطالب تدريبًا: «لا يوجد تدريب مرتبط بحسابك لعرض تقييمه.»

5. اعتبارات التنفيذ والربط

5.1 قيود قاعدة البيانات والمنطق الخادمي

• قيود التوافق بين college_id والعلاقات لا تعتمد على نماذج الواجهة وحدها.
• يجب اختبار كل قاعدة عزل عبر مستخدمين من كليات مختلفة، خصوصًا المعرفات المباشرة للطلبات والملفات والمحادثات.
• طلب الطالب النشط الواحد يحتاج حماية من الإرسال المتزامن (قيد قاعدة بيانات/معاملة)، لا فحصًا شكليًا فقط.
• احتساب ساعات اليوم يعتمد على السجل المعتمد، ويطبق الحد اليومي للتخصص، ولا يخصم الاستراحة.
• في رسائل التقييم والمحادثات، لا يرسل الخادم بيانات لم يصرح الدور بالاطلاع عليها حتى لو أخفتها الواجهة.
• تغيير حالة الفرصة إلى مغلقة أو امتلاء المقاعد يجب أن يعاد التحقق منه وقت إرسال الطلب لمنع سباق التزامن.

5.2 متطلبات التحقق والاختبار

• اختبار قراءة/كتابة معزولة عبر الكليات لكل جدول نطاقي.
• اختبار حالات حساب غير مفعل، بريد غير متحقق، ومحاولات دخول متتالية؛ القفل 15 دقيقة بعد المحاولة الخامسة المتتالية.
• اختبار أن الفرصة لا تظهر خارج كليتها أو تخصصها، ولا تظهر بعد الإغلاق/امتلاء السعة.
• اختبار حفظ المسودة وسحب بيانات الطالب تلقائيًا، وأن PDF اختياري.
• اختبار GPS داخل/خارج نصف القطر، دقة 100 متر مقابل أسوأ من 100 متر، رفض الإذن، وانقطاع الاتصال.
• اختبار أن الدخول الناقص لا يحتسب، والتصحيح لا يدخل مجموع الساعات إلا بعد الاعتماد.
• اختبار خصوصية المحادثات وملاحظات المشرف والتقييمات، وتوثيق الاطلاع الاستثنائي.

6. ملاحظات وافتراضات وأسئلة مفتوحة

هذا القسم لا يضيف متطلبات؛ يحدد ما يلزم حسمه قبل تثبيت المخطط أو الواجهات.

افتراضات تصميمية صريحة

1. قاعدة البيانات: PostgreSQL مع تفعيل RLS لعزل بيانات الكليات.
2. المستخدمون: مستخدم واحد ينتمي لكلية واحدة ودور/أدوار مسندة من جدول صلاحيات؛ تعدد الكليات/الأدوار لم يحسم.
3. الوقت: التخزين UTC مع تحويل إلى منطقة زمنية إلزامية على مستوى الكلية، يضبطها المسؤول الأعلى عند إضافة الكلية؛ يحتسب حضور اليوم وفق تاريخ المنطقة الزمنية للكلية.
4. حقول الهوية: الاسم الأول والأخير إلزاميان لكل المستخدمين؛ الرقم الجامعي إلزامي للطالب؛ واسم الشركة إلزامي لمسؤول جهة التدريب.
5. مقعد الفرصة: seat_limit عدد موجب. المقعد يحجز عند اعتماد مسؤول الكلية النهائي فقط، ولا تدخل الطلبات المنتظرة أو المرفوضة في عدد المقاعد المحجوزة.
6. التدريب: إنشاء سجل trainings عند الاعتماد النهائي، وتخزين نسخة التخصص/المتطلبات التي بدأ عليها التدريب مقترح لتثبيت الحسابات التاريخية؛ التدريبات القائمة تحتفظ بنسخة المتطلبات عند بدايتها؛ وتسري التعديلات على التدريبات الجديدة فقط وفق PRD-07.
7. الموقع: كل موقع له نصف قطر مستقل، والحد الأقصى لدقة GPS يطبق وفق قاعدة 100 متر؛ التقنية الدقيقة لقياس المسافة لم تُحدد.
8. الصور/المرفقات: السيرة الذاتية PDF اختيارية، ومرفقات الطلب الرسمي اختيارية؛ تستخدم سجلات بيانات ملفات منفصلة مع تخزين خاص. أحجام الملفات والفحص الأمني/سياسة الاحتفاظ لم تحدد.
9. التقييم: سجل تقييم واحد لكل تدريب ومعيار واحد لكل بند؛ يسمح الإرسال مرة واحدة. حالات المسودة قبل الإرسال وما إذا كان مسؤول الشركة يستطيع تعديل المسودة تحتاج تثبيتًا.
10. المحادثات: محادثة فردية ثنائية مرتبطة بتدريب واحد، رسائل نصية بلا مرفقات. إضافة المشاركين المتعددين أو مشاركة المحادثات عبر عدة تدريبات غير مشمولة.
11. البلاغ والطلب: تم فصل dispute_reports عن official_requests لتوضيح مسار البلاغ الذي يبرر الاطلاع على المحادثة، ومسار الطلب الرسمي. قد يقرر الفريق دمجهما في جدول موحد بنوع مختلف إذا حافظ على الفصل الأمني والتدقيقي.
12. الحالات الإدارية: أسماء الحالات الداخلية في قاعدة البيانات ترميز تقني مقترح؛ لا تغير الحالات العربية المعروضة أو التسلسل المتفق عليه.

أسئلة تحتاج قرارًا

1. هل يسمح للمستخدم بأكثر من دور أو كلية؟ وهل يمكن لمسؤول الشركة إدارة أكثر من شركة/فرع؟
2. هل اختيار التخصص من حساب الطالب كافٍ، أم يلزم تحقق الكلية من تخصصه/رقمه الجامعي؟
3. هل يمكن للطالب تعديل رسالة الطلب أو استبدال السيرة الذاتية بعد الإرسال؟ وهل تبقى ملفات الطلب متاحة للشركة والكلية والمشرف، وما سياسة حذفها؟
4. هل يمكن أن تكون الفرصة لعدة كليات، أم تنتمي لكلية واحدة فقط؟ PRD الحالي يقصر ظهورها على طلاب الكلية المرتبطة بها.
5. ما البيانات الإلزامية للموقع، وهل يستطيع مسؤول الشركة تعديل/حذف موقع بعد اعتماده؟ وما أثر التعديل على سجل الحضور السابق؟
6. ما تعريف بداية/نهاية التدريب الفعلية وتاريخ نهاية التدريب المتوقع؟ وكيف يتفاعل ذلك مع تواريخ الفرصة ومتطلبات المدة؟
7. هل يسمح بأكثر من سجل حضور يومي أو موقعين مختلفين في اليوم؟ وكيف تُمنع السجلات المكررة أو المتداخلة؟
8. هل يتيح مسؤول الشركة تعديل سجل سبق اعتماده؟ وإذا نعم، هل يلزم سبب وسجل تدقيق وإعادة حساب الساعات؟
9. ما أنواع/دورة حالات طلبات التصحيح والاستثناء، وهل يمكن رفضها دون سبب؟ وهل يقبل مسؤول الشركة طلبًا لتسجيل يوم كامل دون GPS؟
10. هل يحق لمسؤول الشركة تعديل مسودة التقييم قبل الإرسال؟ وما بيانات مسؤول الشركة تظهر للطالب؟
11. كيف يفتح الطالب بلاغ النزاع، وما إجراءات مسؤول الكلية/مراحل القرار، وكيف يسجل ارتباط البلاغ بالمحادثة التي يراد الاطلاع عليها؟
12. ما الذي يعد «طلبًا رسميًا قائمًا» كشرط للاطلاع على محادثة، وهل يجب موافقة مسؤول آخر على الاطلاع؟ ما نطاق المحادثة المسموح عرضه ومدة الوصول؟
13. هل يستطيع الطالب أو جهة التدريب أو المشرف أو مسؤول الكلية بدء محادثة فردية مع أي طرف مرتبط، أم توجد قائمة أزواج محددة؟ هل الرسائل تحذف/تعدل، وهل توجد إيصالات قراءة؟
14. ما أنواع الطلبات الرسمية التي تظهر للمستخدمين، ومن يحق له تقديم كل نوع؟ وهل طلب تغيير المشرف يدار في official_requests أم مسار مستقل؟
15. ما سياسة تعيين المستخدمين لمسؤول شركة/فرع، والتحقق من أهلية الشركة، ورفض/تعطيل الحسابات؟
16. ما سياسة الاحتفاظ بالسجلات والرسائل والمواقع والتقييمات والملفات، وهل توجد آلية لتصديرها أو حذفها؟
17. ما مدد الاحتفاظ بسجل التدقيق، ومن يستطيع استعراضه أو تصديره؟
18. ما حدود حجم ملفات PDF، وفحوصات نوع المحتوى والفيروسات، ومدة صلاحية روابط التنزيل؟
19. ما قواعد المصادقة الإضافية (مثل MFA) وحماية استعادة كلمة المرور؟
20. ما مستهدفات الأداء والتوافر والنسخ الاحتياطي والاستعادة ومتطلبات إتاحة الواجهة؟
21. هل يدعم النظام الإنجليزية أو معايير وصول محددة، إلى جانب الواجهة العربية وRTL؟

────────

نهاية مستند التصميم التقني — المرحلة الأولى
